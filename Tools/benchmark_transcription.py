"""Opt-in paid API benchmark, using generated speech rather than microphone recordings.

Requires Python's websockets package in a development venv. Credentials are read
without executing the env file, and are never printed. Not a runtime app dependency.
"""
import asyncio
import base64
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import urllib.request
import wave

import websockets

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".build/benchmarks"
TEXT = {
    10: "Please ask the AnyVan team to review the ALM report tomorrow morning and confirm the delivery time before lunch.",
    30: "Please ask the AnyVan team to review the ALM report tomorrow morning and confirm the delivery time before lunch. We need to organise the collection for Thursday, the fifteenth of October, at half past nine. The customer has requested a smaller vehicle because the entrance is narrow. Please include the reference number four seven two eight in the confirmation and check that the updated price is two hundred and fifty pounds.",
    60: "Please ask the AnyVan team to review the ALM report tomorrow morning and confirm the delivery time before lunch. We need to organise the collection for Thursday, the fifteenth of October, at half past nine. The customer has requested a smaller vehicle because the entrance is narrow. Please include the reference number four seven two eight in the confirmation and check that the updated price is two hundred and fifty pounds. I also want to summarise what we agreed during the planning discussion. We will start with a small native application, keep the interface simple, and focus on accuracy before adding more features. The first version should work in our usual messaging tools and browser. If the connection fails, keep the recording temporarily so we can retry. Once the result is ready, insert the complete text in the original field and leave the clipboard exactly as it was before.",
}


def api_key():
    value = os.environ.get("OPENAI_API_KEY")
    if value:
        return value
    for line in (Path.home() / ".env").read_text().splitlines():
        match = re.match(r"^\s*(?:export\s+)?OPENAI_API_KEY\s*=\s*(.*)$", line)
        if match:
            parts = shlex.split(match[1], comments=True)
            if len(parts) == 1 and parts[0].startswith("sk-"):
                return parts[0]
    raise RuntimeError("OPENAI_API_KEY not found")


def fixtures():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    result = {}
    for seconds, text in TEXT.items():
        aiff, wav = OUTPUT / f"synthetic-{seconds}.aiff", OUTPUT / f"synthetic-{seconds}.wav"
        if not wav.exists():
            subprocess.run(["/usr/bin/say", "-v", "Daniel", "-r", "175", "-o", str(aiff), text], check=True)
            duration = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(aiff)]))
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(aiff), "-af", f"atempo={duration/(seconds-.25)},apad", "-t", str(seconds), "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)], check=True)
        with wave.open(str(wav)) as audio:
            assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (24000, 1, 2)
            result[seconds] = audio.readframes(audio.getnframes())
    return result


async def realtime(key, pcm, model, delay=None):
    started = time.monotonic()
    async with websockets.connect("wss://api.openai.com/v1/realtime?intent=transcription", additional_headers={"Authorization": "Bearer " + key}, max_size=16_000_000, open_timeout=15) as ws:
        created = json.loads(await ws.recv())
        if created["type"] == "error":
            raise RuntimeError(created.get("error", {}).get("code", "session rejected"))
        config = {"model": model, "languages": ["en"], "keywords": ["AnyVan", "ALM"]}
        if delay:
            config["delay"] = delay
        await ws.send(json.dumps({"type": "session.update", "session": {"type": "transcription", "audio": {"input": {"format": {"type": "audio/pcm", "rate": 24000}, "transcription": config, "turn_detection": None}}}}))
        while True:
            event = json.loads(await ws.recv())
            if event["type"] == "session.updated":
                break
            if event["type"] == "error":
                raise RuntimeError(event.get("error", {}).get("code", "configuration rejected"))
        connected = time.monotonic()
        first_delta = None
        end_audio = None

        async def send_audio():
            nonlocal end_audio
            start = time.monotonic()
            for offset in range(0, len(pcm), 4800):
                await ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": base64.b64encode(pcm[offset:offset+4800]).decode()}))
                # Pace at real-time, including the last 100 ms before fn-up.
                await asyncio.sleep(max(0, start + min(offset + 4800, len(pcm)) / 48000 - time.monotonic()))
            end_audio = time.monotonic()
            await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))

        sending = asyncio.create_task(send_audio())
        try:
            async with asyncio.timeout(len(pcm) / 48000 + 90):
                async for message in ws:
                    event = json.loads(message)
                    if event["type"] == "conversation.item.input_audio_transcription.delta" and first_delta is None:
                        first_delta = time.monotonic() - connected
                    if event["type"] == "conversation.item.input_audio_transcription.completed":
                        assert end_audio is not None
                        return {"handshake_s": connected-started, "release_to_final_s": time.monotonic()-end_audio, "first_delta_s": first_delta, "transcript": event["transcript"]}
                    if event["type"] in ["error", "conversation.item.input_audio_transcription.failed"]:
                        raise RuntimeError(event.get("error", {}).get("code", "transcription failed"))
        finally:
            sending.cancel()
            await asyncio.gather(sending, return_exceptions=True)


def batch(key, seconds):
    boundary = "OnAirBenchmarkBoundary"
    body = bytearray()
    for name, value in [("model", "gpt-transcribe"), ("stream", "true"), ("languages[]", "en"), ("keywords[]", "AnyVan"), ("keywords[]", "ALM")]:
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode())
    body.extend((OUTPUT/f"synthetic-{seconds}.wav").read_bytes())
    body.extend(f'\r\n--{boundary}--\r\n'.encode())
    request = urllib.request.Request("https://api.openai.com/v1/audio/transcriptions", bytes(body), {"Authorization": "Bearer " + key, "Content-Type": "multipart/form-data; boundary=" + boundary})
    start = time.monotonic()
    first = None
    with urllib.request.urlopen(request, timeout=90) as response:
        for raw in response:
            if not raw.startswith(b"data: ") or raw.strip() == b"data: [DONE]":
                continue
            event = json.loads(raw[6:])
            if event.get("type") == "transcript.text.delta" and first is None:
                first = time.monotonic() - start
            if event.get("type") == "transcript.text.done":
                return {"release_to_final_s": time.monotonic()-start, "first_delta_s": first, "transcript": event["text"]}
    raise RuntimeError("No completed transcript")


async def main():
    key = api_key()
    audio = fixtures()
    results = []
    semaphore = asyncio.Semaphore(3)

    async def run(seconds, model, delay=None):
        async with semaphore:
            row = {"seconds": seconds, "path": model, "delay": delay, "synthetic": True}
            try:
                row.update(await asyncio.to_thread(batch, key, seconds) if model == "batch" else await realtime(key, audio[seconds], model, delay))
                print(f'{seconds}s {model} {delay or ""}: final {row["release_to_final_s"]:.3f}s', flush=True)
            except Exception as error:
                # Never stringify request/response objects or headers.
                row["error"] = type(error).__name__
                if isinstance(error, RuntimeError):
                    row["code"] = str(error)[:100]
                print(f'{seconds}s {model} {delay or ""}: {row["error"]}', flush=True)
            results.append(row)
            (OUTPUT / "results.json").write_text(json.dumps(results, indent=2))

    await asyncio.gather(*(run(seconds, model, delay) for seconds in audio for model, delay in [("gpt-live-transcribe", "minimal"), ("gpt-live-transcribe", "low"), ("gpt-live-transcribe", "medium"), ("gpt-transcribe", None), ("batch", None)]))


if __name__ == "__main__":
    asyncio.run(main())
