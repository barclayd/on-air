# Initial transcription benchmark

Measured on 3 October 2026, on this Mac and network. The initial default is **`gpt-live-transcribe`, `delay: low`**, with a warm connection. This is a provisional choice based on a small synthetic probe and a successful real-voice check, not a comprehensive accuracy evaluation.

## End of audio to completed transcript

Seconds, one sample per cell. These numbers exclude clipboard insertion and overlay fade.

| Path | 10-second clip | 30-second clip | 60-second clip |
| --- | ---: | ---: | ---: |
| Live, minimal delay | 0.447 | 0.590 | 0.384 |
| **Live, low delay** | **0.387** | **0.463** | **0.669** |
| Live, medium delay | 0.561 | 0.601 | 0.475 |
| `gpt-transcribe`, Realtime | 1.296 | 1.090 | 1.780 |
| `gpt-transcribe`, streamed file response | 0.684 | 1.441 | 2.535 |

Realtime audio was sent in 100 ms chunks at real-time speed after the session handshake. Timing starts immediately before the final commit. The batch measurement starts before the completed file's HTTP request, so includes uploading it. Realtime handshake time was measured separately (approximately 0.58–1.82 seconds); a cold connection can add delay. The app keeps its connection ready between holds.

The fixtures use macOS's Daniel voice, adjusted to 10, 30, and 60 seconds, with 250 ms of trailing padding. All paths received English and AnyVan/ALM hints. Up to three benchmark jobs ran concurrently, which can introduce contention. The benchmark did not include the British spelling prompt subsequently added to the app.

All paths completed in this run. Low delay recognised ALM in all three fixtures, but confused “lunch” with “launch” in the 10-second fixture. Other settings also made recognition errors; medium delay wrote ARM in the 60-second fixture. These few examples do not establish an accuracy ranking. Repeated real-voice recordings, background noise, and different network conditions are needed before claiming a reliable latency percentile or choosing a different delay.

## Production client and hardware checks

`Tools/TranscriptionSmoke.swift` exercised the production Swift client with two consecutive turns on one connection, using the generated 10-second WAV. Both returned complete expected text; release-to-final times were **0.385** and **0.595 seconds**. This separately checks the app's Swift implementation rather than only the Python benchmark.

The user then tested the signed, installed app with physical fn and the real microphone. It correctly transcribed and pasted: “Please ask the AnyVan team to review the ALM report tomorrow.” No timing was collected for that manual check.

## Reproduce

This is an opt-in, paid API benchmark. It reads `OPENAI_API_KEY` from the environment or the literal assignment in `~/.env`, without executing the file or printing the key. It generates test speech; it does not record the microphone. Python 3.11+, macOS's Daniel voice, and `ffmpeg`/`ffprobe` are required. The Python package is a development dependency only; the app has no third-party dependencies.

```sh
python3 -m venv .build/benchmark-venv
.build/benchmark-venv/bin/pip install 'websockets>=15,<16'
.build/benchmark-venv/bin/python Tools/benchmark_transcription.py
```

Generated WAVs and detailed results, including synthetic transcripts, are stored under `.build/benchmarks/`, which Git ignores. These development fixtures are separate from the app's memory-only handling of microphone recordings. See [testing instructions](TESTING.md) for the Swift smoke check and offline regression suite.

## Version-formatting prompt check

On 3 October 2026, a generated Daniel-voice recording said “Please use version one dot two dot three, rather than version zero dot ten dot two. We should organise the review tomorrow.” Both production transcription paths received the shared British English prompt plus generic guidance to write version numbers as digits separated by periods, with `1.2.3` as an example.

`gpt-transcribe` (retry) returned `1.2.3` and `0.10.2`. `gpt-live-transcribe` still returned the version numbers as words, both with a spoken-to-written example in the prompt and with a more direct formatting instruction. The prompt is accepted, but this probe does **not** establish reliable version formatting for live dictation. No post-processing or extra model call was added. This was a small synthetic check, not a real-voice accuracy evaluation.

Following the user's real-use report of inconsistent formatting, On Air now applies an approved local Swift rule to recognised dotted number sequences before paste or Copy. This is separate from the model behaviour measured above; it adds no API request and does not correct misrecognised audio. See [the rule's scope](DECISIONS.md) and [offline regression coverage](TESTING.md).

Protocol references: [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription) and [file transcription](https://developers.openai.com/api/docs/guides/speech-to-text).
