# Regression testing

Run from the repository root:

```sh
Tools/test.sh
```

The suite currently contains **30 application E2E tests and one visual regression test comparing twelve images**, preceded by credential-parser, PCM/WAV, and clipboard checks. An incremental run takes about a minute on this Mac. It needs macOS 14+, the full Xcode installation selected with `xcode-select`, and an unlocked desktop session with a display. A headless Linux runner cannot run these tests. On a macOS CI machine, run under a logged-in GUI user and retain `.build/e2e/tests.log` and `.build/e2e/artifacts/` on failure.

Tests run serially. Brief glows appear during the run. Leave focus and the clipboard alone during the main interaction test, which explicitly checks that neither changes. Do not pass `--parallel` or run two copies of the suite in one desktop session.

For a focused run:

```sh
Tools/test.sh --filter testWatchdogRecoversMissingFnUpEvent
Tools/test.sh --filter VisualRegressionTests
```

## What the E2E tests actually exercise

`Tools/test.sh` builds a separate `OnAirE2E.app`, with a distinct bundle ID and build directory. XCTest launches a fresh process for every scenario. Tests do not link or import the app module. The application runs its real SwiftUI lifecycle, menu-bar scene, `FunctionKeyMonitor`, `PrototypeController`, timers, `NSPanel`, `NSHostingView`, and renderer.

The test bridge posts `NSEvent`s into the application's event queue. They traverse its production local monitor; another monitor checks that events are not consumed. The bridge cannot set phases or invoke the controller's private start/end methods. Microphone authorization, hardware input, transcription responses, and text insertion are substituted at their boundaries; synthetic PCM samples use the production RMS/normalization function. Real time is used for animation completion, permission polling, envelope response, and the missed-release watchdog.

The bridge exists only when `E2E_TESTING` is explicitly compiled in. Ordinary Debug and Release builds contain no test control channel. The E2E build cannot launch without the driver's temporary directory, never installs a global keyboard monitor, never opens a real microphone, and never prompts for permissions. It leaves the installed On Air app unchanged.

| Area | Regressions guarded against |
| --- | --- |
| Idle/launch | Microphone opens on launch; overlay appears without fn; Dock app policy replaces accessory mode |
| Hold/release | Missing red/blue states, lingering microphone after fn-up, missing fade, unbounded finishing time |
| Real overlay | Empty hosting view, wrong glow color, opaque top of screen, focusable or non-click-through panel, duplicate windows |
| Fn handling | Repeated starts, F/arrow flags mistaken for fn, Escape ending a hold, modifiers/shortcuts not discarded, swallowed keys |
| Tap/concurrency | Short tap enters blue processing; a press during finishing queues another dictation |
| Missed release | Microphone remains active when a release event is swallowed |
| Permissions | Denied/restricted/start failure; delayed grant starts capture after release or applies to another hold; grant needs relaunch |
| Transcription | Partial/unfinished results pasted; duplicate paste; fast results skipping blue; changed focus receiving text; failed clips not retryable; retry reopening microphone; stale results after lock |
| Audio | Silence/loud PCM mapping, level decay, input change silently restarts capture, old callbacks affect a new hold |
| Lifecycle | Sleep/lock/display changes leave capture active; cancelled completion hides a newer hold; quit leaves the panel/meter active |
| Desktop integrity | Fn cycle changes foreground application or clipboard change count |
| Motion | Reduce Motion responds to voice/time; glow/waveform geometry or colors drift from the reference images |

The red/blue E2E checks cache the **actual overlay's hosting view** into a bitmap, without capturing other apps. Their assertions inspect transparency and color distribution. The twelve fixed visual references separately compare `GlowRenderer` at known frames, in dark and light contexts, with a small pixel tolerance. Recording references include opposite decorative phases and a static Reduce Motion recording. The lower screen band has its own comparison so a missing thin waveform cannot hide in an otherwise unchanged image.

## Failure evidence

- `.build/e2e/tests.log` and `build.log`: test runner and application build output.
- `.build/e2e/artifacts/<test>-<id>/`: app log, commands, initial/final state, last observed state, and any rendered window images.
- `.build/e2e/artifacts/visual-<id>/`: actual images and renderer log.

Timeout errors identify the artifact directory. Polling waits for observable behavior, rather than relying on fixed sleeps to guess when a UI is ready. The explicit timed observation in the cancellation test lasts past the old completion deadline to catch a brief or delayed resurrection. Teardown quits the child app and falls back to terminating it after a bounded wait.

## Updating visual references

`Tests/EndToEnd/Baselines/` contains the native preview images reviewed for the initial prototype, generated on Apple silicon/macOS 27 with Xcode 27. Baselines are never overwritten by a test run. Do not replace them just because a test is red. Inspect the actual image against the reference and the supplied film first; check whether a macOS renderer change or an intentional design change explains the difference.

For an intentional design change, render into a separate review directory:

```sh
mkdir -p .build/visual-review
xcrun swiftc -parse-as-library OnAir/Overlay/GlowFrame.swift \
  OnAir/Overlay/GlowRenderer.swift Tools/RenderPreview.swift \
  -o .build/visual-review/render-preview
.build/visual-review/render-preview .build/visual-review
```

After reviewing the affected images, copy only those PNGs into `Tests/EndToEnd/Baselines/` and run the whole suite. Keep the visual change and its updated references together in review.

## Hardware checks that remain manual

This is app-process E2E coverage with controlled OS inputs, not a claim that macOS permissions and hardware were tested. It does not exercise the global monitor across other processes, actual TCC dialogs, physical microphone selection/disconnection, the system's Globe-key setting, or actual full-screen Space routing. The panel's full-screen/Space flags and pinning within a cycle are automated; selection of the destination display and behavior while switching displays/Spaces still need a physical smoke test.

Before shipping input or window-management changes, use the normal signed app in Codex, Chrome, and Slack. Hold/release physical fn, try a short tap and fn+arrow/Delete, confirm the microphone indicator disappears on release, move focus between displays, and check a full-screen app. Confirm the menu's status and Quit action, and try the system Reduce Motion setting. Transcription state and insertion decisions are covered with fixtures. Core checks use a private pasteboard (never the general clipboard) to verify multi-item/multi-format restoration and protection of a newer user copy. `Tools/TranscriptionSmoke.swift` separately exercised the production Swift client against OpenAI for two consecutive generated-audio turns. The user verified physical fn, real microphone capture, recognition of AnyVan/ALM, and pasting on 3 October 2026. Cross-app/display/Space coverage and broader real-voice accuracy still need manual evaluation.

Clipboard failure checks cover a payload exceeding the 32 MiB snapshot limit and an advertised representation whose provider returns no data. Both must leave the private pasteboard intact. Direct-input checks reconstruct a long transcript from the generated Unicode events, including emoji and combining characters, and reject newlines, control characters, and oversized graphemes before any events are created for delivery. These tests never post the events; they verify framing and preservation, not whether another app accepts synthetic Unicode input. Exercise that fallback manually in each supported destination before claiming compatibility.

## Explicit live-API checks

Normal regression tests make no OpenAI calls. Live checks are opt-in and bill the API key in `~/.env`:

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  OnAir/Transcription/Transcribing.swift OnAir/Transcription/APIKeyStore.swift \
  OnAir/Transcription/OpenAITranscriber.swift Tools/TranscriptionSmoke.swift \
  -o .build/transcription-smoke
.build/transcription-smoke .build/benchmarks/synthetic-10.wav
```

The generated WAV comes from `Tools/benchmark_transcription.py`; see `BENCHMARKS.md`. The smoke tool never opens a microphone or writes the key to Keychain. It checks for a complete expected result and reports timing, without printing the transcript or credentials.
