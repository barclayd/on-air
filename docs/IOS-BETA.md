# On Air iPhone beta

The iOS 18+ app, keyboard and Live Activity are in the `OnAirPhone` scheme.
Use your own OpenAI key in Setup; it is verified before being saved to the
iPhone's device-only Keychain. No key belongs in the repository or build settings.

## Trying the beta

1. Install the signed app, open Setup and verify your OpenAI key.
2. In Settings → General → Keyboard → Keyboards, add On Air and enable Allow
   Full Access. Basic typing works without Full Access; dictation commands need it.
3. In On Air, tap **Enable keyboard for 5 minutes**. Return to Notes or Messages,
   select the On Air keyboard with the globe key, and tap **Dictate**.
4. Finish with the tick. An unchanged, visible destination receives the final
   transcript once. If the destination changed, use **Insert transcript** or the
   app's explicit **Copy transcript** instead.
5. Use **Turn off** in the app or Live Activity to release the microphone.

Ready mode really keeps the microphone active. Audio outside a dictation is
discarded, and the ready session expires after five minutes. A dictation is
limited to five minutes. Cancellation, audio interruption, route changes and
protected-data loss end capture; the app does not silently resume.

Cold keyboard activation currently uses an explicit visit to On Air followed
by a manual return. No private host-app launcher or automatic arbitrary-app
return is used. The Shortcuts/Action Button intent and Control Centre button
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

The implementation has passed sixteen portable transport, insertion and real PCM
mailbox checks, the existing Mac core checks, two iPhone simulator UI checks and
a Mac Debug build. The Mac E2E run covered 75 tests; a blue endpoint rounding
regression found there was fixed and both visual checks rerun successfully with
the original baselines. Development signing now succeeds for the app and both
extensions with the shared App Group.
The simulator checks establish presentation and setup behaviour, not working
physical microphone capture or background keyboard dictation.

Device installation, TestFlight delivery, twenty consecutive real dictations, audio
routes/interruptions, energy use, lock handling and real host-app compatibility
are still pending. Follow the acceptance matrix in [the approved plan](IOS-BETA-PLAN.md).
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
