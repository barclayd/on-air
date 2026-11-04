# On Air iPhone beta

The iOS 18+ app, keyboard and Live Activity are in the `OnAirPhone` scheme.
Use your own OpenAI key in Setup; it is verified before being saved to the
iPhone's device-only Keychain. No key belongs in the repository or build settings.

## Trying the beta

1. Install and open the signed app. Tap **Allow microphone access**, then **Allow** in Apple’s permission prompt. Setup shows **Allowed** if access was already granted, or **Open Settings** if it was denied. Verify your OpenAI key in Setup.
2. In Settings → General → Keyboard → Keyboards, add On Air and enable Allow
   Full Access. Use the globe button to return to your usual typing keyboard.
3. Place the cursor in your app and select On Air from the keyboard list.
   Choosing the keyboard starts one dictation; there is no enable/disable switch.
4. Tap **Done** to stop audio capture immediately. The shared Mac animation
   changes from the red listening glow to the blue processing wave. After
   insertion, a tick appears and the keyboard returns to normal typing.
   No further dictation starts until On Air is chosen again.
5. Hiding or switching keyboards cancels capture. Audio interruption, route
   changes and protected-data loss also stop the microphone.

Apple does not allow keyboard extensions to access the microphone directly.
When the containing app is asleep, keyboard selection attempts a public SwiftUI
URL handoff to `onair://keyboard`; On Air prepares microphone capture and the
user returns using iOS's native back control. If iOS refuses the automatic URL
open, the keyboard provides an **Open On Air** link. No private host-app launcher
or arbitrary-app return is used. An unfinished handoff shuts itself down rather
than leaving the microphone ready indefinitely. While the containing app is
already running, selection can start dictation directly through the shared
command channel. Cold handoff and background restart still require device checks.
Each active dictation is bounded to limit its in-memory audio, and completed
results and failed retry audio retain their existing private expiry limits.

The Shortcuts/Action Button intent and Control Centre button
start or finish dictation through the containing app and require a Live Activity
for background starts. Their physical-device behaviour remains to be checked.

## Local checks

```sh
Tools/test-ios.sh
Tools/test-core.sh
python3 -m unittest discover -s Tools/IOSReleaseTests -v
```

Set `IOS_SIMULATOR_UDID` to use a specific simulator; otherwise the script creates
or reuses its isolated `On Air CI` simulator. The CI job runs these same checks.
`OnAirInputFixture` is a separate simulator presentation/input fixture: its
recording levels are synthetic, and it never uses the microphone or OpenAI.
It is not embedded in the iPhone app or its archive.

The portable package includes transcription, formatting, rendering and session
contracts. Mac targets import it; standalone compiler checks compile the same
sources directly. Credentials and OS input/audio ownership remain platform-specific.

## Validation status

The implementation has passed twenty portable transport, insertion and real PCM
mailbox checks, the existing Mac core checks, iPhone simulator UI checks and
a Mac Debug build. The Mac E2E run covered 75 tests; a blue endpoint rounding
regression found there was fixed and both visual checks rerun successfully with
the original baselines. Development signing now succeeds for the app and both
extensions with the shared App Group.
The simulator checks establish presentation and setup behaviour, not working
physical microphone capture or background keyboard dictation. Startup failure/recovery and permission revocation use the production coordinator with controlled audio/network boundaries. Stale connection status preserves the last known consent and error; it never serves as proof of live capture. Optional Live Activity creation cannot block keyboard dictation. Native permission actions distinguish undecided, allowed and denied access.

On an existing installation, Apple does not repeat a permission prompt that was already answered. Check **Setup → Microphone** for the current status. After a startup failure, **Try microphone again** prepares capture in the foreground; a call or another higher-priority audio session may need to finish first. Startup diagnostics record error domain/code and foreground status only.

The initial development beta was installed on the paired iPhone Duo. Exact
build availability and TestFlight delivery status are recorded on the
[implementation PR](https://github.com/barclayd/on-air/pull/30). Twenty consecutive
real dictations, audio routes/interruptions, energy use, lock handling and real
host-app compatibility still need acceptance checks. Follow the matrix in
[the approved plan](IOS-BETA-PLAN.md).
Do not describe this early simulator build as an installed, verified beta.

The [iOS release instructions](RELEASING.md#internal-iphone-beta) describe local
account-based delivery and the separate internal-only CI workflow. Build
provenance records the exact source, all three signed targets and the IPA hash;
an upload alone does not establish internal tester access.

Completed text uses a protected, backup-excluded App Group file for delivery.
It expires after five minutes and is deleted when consumed or on the next
execution after expiry. Raw audio is never written to disk. Failed audio is
retained only in memory for up to five minutes for an explicit retry. Ordinary
typed text and surrounding field content are not sent to the app or OpenAI.
