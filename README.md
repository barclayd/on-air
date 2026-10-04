# On Air

A native macOS dictation app with the visual design from the supplied On Air film. Hold **fn / Globe**, speak, and release. A red glow responds to your voice; a blue waveform appears while OpenAI finishes the transcript, then the completed text is pasted into the original input field.

Audio streams to `gpt-live-transcribe` while fn is held, using low delay, English, and the hint **ALM**. There is no separate AI rewrite step. Failed recordings can be retried with `gpt-transcribe`. Audio is held only in memory, never written to disk.

A local Swift rule formats clear dotted version numbers before insertion or Copy: **one dot two dot six → 1.2.6**. It requires at least three numeric components and a spoken “dot”, supports mixed words/digits and English number words through 999, and preserves surrounding text. Two-component phrases and unsupported/ambiguous number components stay unchanged. No additional API call is made.

Add and verify your OpenAI key during setup or in **Settings…**; it is stored in macOS Keychain. Existing developer installs can still import a literal `OPENAI_API_KEY` assignment from `~/.env` on first use. That file is parsed, never executed, and is not re-imported after removing a key in Settings. API keys, dictation notes, and transcript contents are excluded from app diagnostic logs.

## Build and run

Open `OnAir.xcodeproj` in Xcode, select **OnAir**, and run. The project uses Swift 6, built-in frameworks, Hardened Runtime, and the Audio Input entitlement; it is not sandboxed. Deployment target: macOS 14 or later.

The project is configured for the existing Apple Development signing identity on this Mac (team `R2GGK3VN2C`). Using the same bundle ID and signing identity keeps permission grants stable across rebuilds.

```sh
xcodebuild -project OnAir.xcodeproj -scheme OnAir \
  -configuration Debug -derivedDataPath .build build
open ".build/Build/Products/Debug/On Air.app"
```

The menu bar provides status, **Set up On Air…**, **Settings…**, **Quit On Air**, and **Copy transcript** or **Retry transcription** when needed. Settings is also available through the standard On Air application menu and **⌘,** while the app is active. The app appears in the Dock while setup or Settings is open; closing the last window returns to menu-bar-only operation.

## Settings

The native settings window follows the supplied On Air Settings design: a compact dark window with dictation notes, recording glow, and an OpenAI API key.

- **Dictation notes** save automatically on this Mac and supplement the transcription context for both live dictation and retry. Keep them concise (up to 1,000 characters). Oversized edits show an error and preserve the previous usable notes. Changes apply to the next dictation without interrupting a current hold or finalisation.
- **Recording glow** offers eleven levels from 0 (faint) to 10 (fuller), with the original appearance at 5. The preview uses no microphone. Changes save automatically, apply smoothly during a hold, and respect Reduce Motion; the blue finishing animation stays unchanged.
- **Verify** checks the key against the configured OpenAI transcription session without opening the microphone or sending audio. Only accepted keys are saved to Keychain. Existing stored keys are rechecked when Settings opens; offline/error states do not claim verification.
- **Show / Hide** reveals only the draft key. A saved key shows its last four characters. **Remove** deletes On Air’s Keychain entry and prevents the legacy `~/.env` fallback from re-importing it; it does not revoke the key at OpenAI or modify `~/.env`.

Notes are context hints, not a separate AI cleanup step or a guarantee of exact wording. The local version-number formatter still runs after transcription.

The signed functional Release build is installed at `/Users/danbarclay/Applications/On Air.app`.

## macOS setup

On first launch, a native setup window follows the supplied On Air Onboarding design. It can be closed at any time and reopened from **Set up On Air…** in the menu bar or the link in Settings.

1. **Microphone** requests the native permission when its switch is clicked. Previously denied access opens Privacy & Security → Microphone; restricted access explains that administrator help is needed.
2. **Accessibility** opens the relevant privacy pane so you can enable On Air. On macOS 27 this pane is named **Device Control and Data Access**. Accessibility covers both the existing global fn monitor and pasting; On Air does not request separate Input Monitoring access.
3. **OpenAI API key** is saved in Keychain only after actual transcription-session verification. Existing keys are reused and verified automatically. There is no recording or audio transmission during verification.

These are the only required setup tasks. The next screen also offers **Dictation notes — Optional**, above the API key as in the design. Notes can be left blank and save immediately to the same preference shown in Settings. Already-granted permissions are skipped; a stored key is verified automatically, then **Continue** leaves time to review notes. Existing notes and credentials are preserved.

The window retains the HTML’s 540 × 500 layout, compact switches, and red-glow → blue-waveform → checkmark sequence. Permission rows reflect live macOS status, including changes made while System Settings is frontmost. A click, a return to the app, or a cached permission callback never counts as a grant. **Done** rechecks both permissions and the verified key. The finish animation is decorative; only fn can start recording. On the ready screen, holding fn depresses the illustrated key and makes the checkmark and bottom glow pulse red with your voice. Releasing fn shows a blue waveform until transcription finishes, then restores the checkmark. Reduce Motion preserves static colour feedback without pulsing or morphing.

Changing fn / Globe to **Do Nothing** is not required. If the emoji picker or another macOS action interferes with dictation, that preference can be changed in System Settings → Keyboard as optional troubleshooting. It is not part of onboarding.

Completed setup is remembered. Subsequent launches reopen setup if a required permission or stored key is missing. Both setup and Settings can remain open without one closing the other's application menu or cancelling its key verification. System Settings links include manual navigation guidance if opening fails.

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
- If the clipboard cannot be fully preserved, ordinary single-line dictation uses Unicode keyboard input without changing the clipboard. Multiline/control text uses **Copy transcript** instead. The same destination and modifier checks apply; compatibility of direct input depends on the receiving app.
- On API failure or a 20-second finalisation timeout, one failed clip stays in memory for up to five minutes for **Retry transcription**. Retry never activates the microphone. A new hold, success, sleep/lock, or quitting clears it. Uncopied results also expire after five minutes.
- Capture retention is bounded to eight minutes per hold; ordinary dictations are expected to be 10–60 seconds. The socket stays warm while the app is running; the microphone does not.

## Release pipeline

GitHub Actions checks app, project, test, and app-pipeline changes with core tests and a universal unsigned DMG build. Website/docs-only changes skip app CI. Version tags trigger Developer ID signing, Apple notarization, and GitHub Releases publication after verification. Manual runs can produce a notarized artifact without publishing.

Each release includes a versioned DMG and an identical `On-Air.dmg` for the website's [permanent latest-stable download link](https://github.com/barclayd/on-air/releases/latest/download/On-Air.dmg), which starts working after the first stable release is published. Older versions remain on [GitHub Releases](https://github.com/barclayd/on-air/releases). See [release setup and instructions](docs/RELEASING.md) for the Apple credentials and versioning.

## Regression tests

```sh
Tools/test.sh
```

Runs 49 app-process E2E tests and a visual regression test covering twelve reference images, plus checks for onboarding, settings, credential parsing, PCM/WAV framing, version formatting, and clipboard preservation. Coverage includes first-launch setup, permission denial/revocation, key-gated readiness, preservation of saved notes/keys, automatic reuse of existing access, optional notes review and validation, shared-window lifecycle, native Settings commands, notes persistence, key verification/removal, safe settings changes during dictation, final-only pasting, formatted versions in live/retry/Copy results, changed focus, failure/retry, fn handling, permissions, lifecycle interruptions, and native overlay rendering. Each E2E test launches a fresh app with controlled keyboard, microphone, transcription, credentials, and insertion inputs. It does not record you or call OpenAI. Test controls are excluded from normal Debug and Release builds.

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
