# On Air — agreed direction

Interview date: 3 October 2026.

## Current delivery

The initial delivery was a visual prototype. On 3 October 2026 the user explicitly approved adding working transcription and pasting, reusing the OpenAI key in `~/.env`. The functional build is installed and the user verified that the spoken test sentence was transcribed and pasted correctly. The user subsequently requested the supplied On Air Settings design, accessible from the menu bar and standard macOS Settings command. On 4 October 2026, the user requested a native guided setup based on the supplied On Air Onboarding design, with permission validation and direct System Settings navigation.

- Voice-responsive, soft red glow along the bottom of the screen while holding fn / Globe. Subtle variations in height and pulse strength drift across it, with a different starting phase per hold. The user approved decorative asymmetry when directional audio is unavailable; this does not claim to locate the speaker.
- On release, cool to blue, collapse into a thin travelling waveform, then fade out.
- The film's title cards, captions, fn illustration, demo Notes window, and word-by-word typing are presentation elements, not app UI.
- Keep the overlay on the destination app's display, chosen at fn-down. No mouse interception or focus stealing.
- One active dictation at a time. Fn-down and fn-up are the only recording controls; no Escape, toggle, or buttons.
- If another key is used during a hold, let the shortcut work normally and discard on fn release.
- Follow the microphone selected in macOS; keep the chosen input fixed for the hold.
- Native onboarding uses the supplied dark permission-card and blue-checkmark design, adapted to the real prerequisites. It is dismissible and available again from the menu bar and Settings.

## Functional implementation and retained decisions

- Personal native macOS app, Swift only, built-in frameworks, stable development signing, no App Sandbox.
- Benchmark representative **10-, 30-, and 60-second** dictations before choosing a transcription engine.
- English with British spelling; retain **ALM** as a keyword hint. Vocabulary editor later.
- The shared live/retry prompt adds: “Write spoken version numbers as digits separated by periods, for example version 1.2.3.” It makes no assumption about the topic of the dictation. A synthetic API check converted the versions in the retry path but still returned words in the live path; see [benchmark notes](BENCHMARKS.md).
- The user subsequently approved a deterministic local Swift formatter. Completed live and retry results use the same formatter before insertion or retention for Copy. Three or more numeric components with at least one spoken “dot” become a dotted number (`one dot two dot six` → `1.2.6`). Components accept digits, English cardinal words through 999, or digit-by-digit words preserving leading zeroes. The rule leaves two-component phrases, ordinary prose, existing numeric versions, and unsupported components unchanged; it does not cross sentence/newline boundaries or infer missing/misheard numbers. No additional API call or AI cleanup is introduced.
- Regression fixtures require conservative handling of fractional/large-scale continuations, adjacent signs/ranges, currency/percent markers, paths, and invisible identifier joiners. These keep the entire ambiguous phrase unchanged. Independent prose after a valid version (such as “and one hundred examples”) and terminal punctuation still permit conversion. This is a bounded textual rule, not semantic recognition of every possible version context.
- Prioritise compatibility with **Codex, Chrome, and Slack**.
- Match Wispr Flow's responsive hold/speak/release experience. No separate AI cleanup or rewriting stage.
- Prefer fewer recognition errors at about one second over roughly half a second with noticeably more mistakes. Around 700 ms remains an initial aspiration, not a verified performance guarantee.
- Begin with OpenAI `gpt-live-transcribe` and `gpt-transcribe` benchmarks; another provider is allowed if the evidence favours it. Select model and delay from measurements.
- Keep the transcription connection ready while On Air runs. The microphone stays off between fn holds.
- Auto-paste only a completed transcript, never accumulated partial text on a deadline.
- Only auto-paste if the original text field is still focused. Otherwise keep one temporary result available for Copy, without a history.
- Preserve clipboard contents around pasting; don't overwrite a newer clipboard change when restoring.
- If a complete clipboard snapshot is unavailable or exceeds 32 MiB, try Unicode keyboard input for single-line text, leaving the clipboard untouched. Recheck the original destination and released modifiers before posting to that application. Newlines/control characters and unsupported payloads retain the existing Copy fallback. This is a delivery fallback, not a transcript rewrite.
- On transcription failure, retain only the failed clip in memory for up to five minutes. Offer Retry transcription, which does not activate the microphone. Clear it after success, a new dictation, or quitting. Never persist audio to disk.
- API key in Keychain. No On Air cloud account.
- Settings contains auto-saving dictation notes and verified Keychain credentials, matching the supplied HTML reference. Notes supplement the shared live/retry prompt, with a 1,000-character limit and no cleanup pass. The native Settings scene is reachable through the menu bar and the standard application Settings command (⌘,). A normal app menu/Dock presence exists while the window is open, then accessory mode resumes on close.
- Key verification authenticates and configures a transcription session without recording or sending audio. A successful verification must also save to Keychain before showing success. Cancelled/stale verification cannot save a replaced/removed key. Removing a key disables legacy automatic dotenv import. Configuration changes wait until dictation has finished before refreshing its warm connection.
- A dedicated vocabulary editor, launch at login, and sounds remain deferred.

## Implementation update — 3 October 2026

- Capture now uses `AVCaptureSession` with the selected microphone and PCM16 output. The original AVAudioEngine implementation changed its AUHAL device after graph creation, causing startup configuration notifications to stop capture on this Mac. That interruption discarded the hold and skipped blue. The user has verified the replacement works through transcription and pasting.
- The initial benchmark selected `gpt-live-transcribe` at low delay. Generated 10/30/60-second fixtures finished 0.39/0.46/0.67 seconds after release. These are provisional synthetic measurements, not an accuracy evaluation of the user's voice. See `BENCHMARKS.md`.
- The app imports the authorised key from `~/.env` into Keychain on first use. It does not execute that file, expose the key in logs, or copy it into the repository.
- Automatic finalisation has a 20-second deadline. Retention is bounded to eight minutes per hold; retry uses a memory-only WAV upload and never activates capture.

### Clipboard-dependent missing insertion

On 3 October, diagnostic logs showed completed transcripts and an unchanged destination, followed by a failed clipboard snapshot. The same installed build later pasted successfully once the clipboard was readable again. The exact earlier clipboard representation was not recorded; the failure could have been unavailable data, the size limit, or a change during capture. The version-formatting update changed only the transcription prompt and did not alter the insertion code.

[OpenWhispr's clipboard manager](https://github.com/OpenWhispr/openwhispr/blob/85b01157f597036ad88c4901cea8d71ab8e46a43/src/helpers/clipboard.js#L795-L870) saves common text, HTML, RTF, and image formats, then restores them after a native Command-V paste. On Air retains its stricter preservation of arbitrary formats and multiple items and uses clipboard-free input when a full snapshot cannot be made. Fixed diagnostic reason labels identify future failures without recording transcripts, clipboard contents, or field contents.

## Research corrections

- Official OpenAI docs distinguish transcription during incoming audio (`gpt-live-transcribe`) from completed files or committed turns (`gpt-transcribe`). A third benchmark candidate worth considering is `gpt-transcribe` over a warm Realtime socket, which overlaps upload with speaking even though model transcription starts after commit.
- Wispr announced its own **Canto** speech model on 17 September 2026. Do not claim that Wispr Flow currently uses `gpt-live-transcribe`.
- The OpenWhispr source reports slow live-model completion in its tests. Treat that as a hypothesis to measure on representative audio, not a guaranteed property of the API.

Sources: [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription), [Wispr Canto](https://wisprflow.ai/canto), [Wispr latency goals](https://wisprflow.ai/post/technical-challenges), [OpenWhispr realtime client](https://github.com/OpenWhispr/openwhispr/blob/main/src/helpers/openaiRealtimeStreaming.js).

## Onboarding implementation — 4 October 2026

- Two short steps: macOS permissions/fn configuration, then optional dictation notes and verified OpenAI credentials, followed by the ready screen. Existing saved keys are reused and checked. Only a verified saved key plus valid notes, granted permissions, and explicit fn-setting confirmation can finish setup.
- System APIs validate Microphone and Accessibility continuously while the window is open, including when System Settings is frontmost. Requests are made in response to their switches, not automatically at launch. Denied access opens the correct pane; restricted access explains the limitation.
- No separate Input Monitoring request: [Apple’s event-monitor documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html) states that Accessibility trust permits global key monitoring, matching the existing NSEvent implementation.
- fn/Globe → Do Nothing is a user-confirmed setting, never presented as an automatic system check. Keyboard settings opens directly; On Air does not mutate undocumented system preferences.
- Setup follows [Apple’s onboarding guidance](https://developer.apple.com/design/human-interface-guidelines/onboarding): brief, dismissible, contextual requests, native controls, and easy reopening. The completion animation never accesses the microphone and becomes a static checkmark with Reduce Motion.
- The revised middle-screen design shares the notes editor and credential state with Settings, backed by the same model, UserDefaults, and Keychain. Valid notes persist immediately, including clearing them; oversized notes keep the previous saved value and block completion with an inline error. Generic placeholder text is retained.
- The HTML’s automatic transitions run after permissions become ready (650 ms) and after an explicit new-key verification succeeds (700 ms). Closing setup or losing prerequisites cancels pending navigation. Editing notes pauses completion and makes Continue available; returning users with a saved key always get Continue in the existing Verify position. Advancing applies pending notes immediately without a duplicate debounce refresh.
- Visual dimensions, colours, compact controls, SVG icon paths, and the full 4.95-second canvas sequence follow the HTML. Native window chrome, real permission/key validation, explicit fn configuration, and fn-only recording are documented exceptions; see [onboarding design fidelity](ONBOARDING-DESIGN.md).
- Settings and setup share verification without cancelling each other. A completed healthy install launches in menu-bar mode; missing permissions or credentials reopen setup for repair.
