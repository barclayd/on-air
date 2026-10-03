# On Air

A native macOS dictation app with the visual design from the supplied On Air film. Hold **fn / Globe**, speak, and release. A red glow responds to your voice; a blue waveform appears while OpenAI finishes the transcript, then the completed text is pasted into the original input field.

Audio streams to `gpt-live-transcribe` while fn is held, using low delay, English, and the hints **AnyVan** and **ALM**. There is no separate AI rewrite step. Failed recordings can be retried with `gpt-transcribe`. Audio is held only in memory, never written to disk.

The key is imported from the literal `OPENAI_API_KEY` assignment in `~/.env` on first use and stored in macOS Keychain. The file is parsed, never executed. API keys and transcript contents are excluded from app diagnostic logs.

## Build and run

Open `OnAir.xcodeproj` in Xcode, select **OnAir**, and run. The project uses Swift 6, built-in frameworks, Hardened Runtime, and the Audio Input entitlement; it is not sandboxed. Deployment target: macOS 14 or later.

The project is configured for the existing Apple Development signing identity on this Mac (team `R2GGK3VN2C`). Using the same bundle ID and signing identity keeps permission grants stable across rebuilds.

```sh
xcodebuild -project OnAir.xcodeproj -scheme OnAir \
  -configuration Debug -derivedDataPath .build build
open ".build/Build/Products/Debug/On Air.app"
```

There is no Dock icon, setup window, or settings window. The menu bar provides status, **Quit On Air**, and **Copy transcript** or **Retry transcription** when needed.

The signed functional Release build is installed at `/Users/danbarclay/Applications/On Air.app`.

## macOS setup

- Allow **Accessibility** for On Air in System Settings → Privacy & Security, so it can observe fn in other apps. macOS prompts on launch; On Air starts observing keys as soon as the grant is detected.
- Allow **Microphone** when macOS asks on your first fn hold. Release fn after granting access and hold it again to try the glow.
- Set System Settings → Keyboard → **Press 🌐 key to → Do Nothing**, so macOS doesn't also open its emoji picker or dictation.

These are native macOS permission dialogs; a custom onboarding flow is deferred.

## Interaction

- Only fn-down starts a hold; only fn-up finishes one. No toggle, Escape control, or start/stop button.
- Pressing another key during the hold leaves that shortcut untouched and discards the dictation on release.
- Taps shorter than 150 ms fade without a processing phase.
- One hold at a time. Fn presses during the blue phase are ignored until a fresh press after it finishes.
- The overlay is click-through, never takes focus, and stays on the destination window's display for the entire cycle. It also appears over full-screen apps.
- The system-selected microphone is pinned for each hold with an `AVCaptureSession`. A disconnected input or capture failure stops capture instead of silently changing microphones mid-hold.
- The microphone stops immediately on release. Late permission replies and queued audio callbacks cannot restart it.
- Sleep, session lock, or a display configuration change clears the overlay and stops capture.
- The red glow subtly varies its height and pulse intensity across the screen. Voice level drives the strength; a smooth decorative drift gives each hold a different starting balance. This is not sound-source tracking.
- Reduce Motion uses a quiet, static glow and line with colour/opacity transitions.
- Only a completed transcript is pasted. If the original field or its selection has changed, use **Copy transcript** in the menu. Secure fields and unrecognised accessibility targets also use this fallback.
- Clipboard items and formats are restored after ⌘V; a newer user copy is never overwritten.
- On API failure or a 20-second finalisation timeout, one failed clip stays in memory for up to five minutes for **Retry transcription**. Retry never activates the microphone. A new hold, success, sleep/lock, or quitting clears it. Uncopied results also expire after five minutes.
- Capture retention is bounded to eight minutes per hold; ordinary dictations are expected to be 10–60 seconds. The socket stays warm while the app is running; the microphone does not.

## Release pipeline

GitHub Actions checks app, project, test, and app-pipeline changes with core tests and a universal unsigned DMG build. Website/docs-only changes skip app CI. Version tags trigger Developer ID signing, Apple notarization, and GitHub Releases publication after verification. Manual runs can produce a notarized artifact without publishing.

Each release includes a versioned DMG and an identical `On-Air.dmg` for the website's [permanent latest-stable download link](https://github.com/barclayd/on-air/releases/latest/download/On-Air.dmg), which starts working after the first stable release is published. Older versions remain on [GitHub Releases](https://github.com/barclayd/on-air/releases). See [release setup and instructions](docs/RELEASING.md) for the Apple credentials and versioning.

## Regression tests

```sh
Tools/test.sh
```

Runs 30 app-process E2E tests and a visual regression test covering twelve reference images, plus checks for credential parsing, PCM/WAV framing, and clipboard preservation. Coverage includes final-only pasting, changed focus, fast results, failure/retry, fn handling, permissions, lifecycle interruptions, and native overlay rendering. Each E2E test launches a fresh app with controlled keyboard, microphone, transcription, and insertion inputs. It does not record you or call OpenAI. Test controls are excluded from normal Debug and Release builds.

Requires Xcode and a logged-in macOS desktop session. Test logs and window captures go to `.build/e2e/`. See [testing documentation](docs/TESTING.md) for coverage, limitations, focused runs, and updating visual references.

## Visual verification

`Tools/RenderPreview.swift` renders the same native SwiftUI Canvas used in the app into recording/processing previews. This is an offline development tool, not another way to activate recording.

```sh
mkdir -p .build/previews
xcrun swiftc -parse-as-library \
  OnAir/Overlay/GlowFrame.swift OnAir/Overlay/GlowRenderer.swift \
  Tools/RenderPreview.swift -o .build/render-preview
.build/render-preview .build/previews
```

See [benchmark results](docs/BENCHMARKS.md), [testing details](docs/TESTING.md), [product decisions](docs/DECISIONS.md), and the [distribution recommendation](docs/DISTRIBUTION.md).
