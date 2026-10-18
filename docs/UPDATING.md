# In-app updates

On Air uses one Sparkle 2.10.0 standard updater, shared by the application menu when Settings is open and the Updates section in Settings. The menu bar dropdown keeps its existing Settings and Quit commands without an additional update item. Settings shows the installed version, an automatic-check preference, and the check result. Sparkle supplies the normal macOS update, download, installation, error, and relaunch windows.

Automatic checks run daily by default; users can disable them. Downloads and installations require a user action. Scheduled discoveries change the Settings button and application menu command to **Update Available…** and show the available version in Settings. They do not bring On Air to the foreground or open an update alert. Selecting the reminder brings Sparkle's existing update session forward instead of starting a second one.

Manual checks are unavailable during recording, transcription, or unresolved Copy/Retry recovery. If installation was already requested before dictation began, Sparkle's relaunch delegate waits until that work is resolved. This does not change the recording glow, status text, capture target, or paste behavior.

## Delivery and persistence

The stable HTTPS feed is `https://github.com/barclayd/on-air/releases/latest/download/appcast.xml`. It contains the newest stable full DMG, with a version-specific URL. Releases are assembled as complete drafts before publication; prereleases never advance the stable feed. Delta downloads are deliberately disabled for this small app.

Both the feed and archive require Ed25519 signatures. The app verifies the archive before extraction and never relaxes signed-feed validation after repeated failures. Developer ID signing, Hardened Runtime, notarization, and stapling still apply; Sparkle does not replace any of those requirements. The release script explicitly signs embedded helpers inside out, verifies the signatures, and generates the feed only after the final DMG bytes are ready. See [RELEASING.md](RELEASING.md) for the signing key and operational procedure.

An update replaces only the application bundle. Keep bundle identifier `com.danbarclay.onair`, team `R2GGK3VN2C`, existing UserDefaults keys, and Keychain service/account unchanged. Sparkle owns its automatic-check preference; On Air does not reset it at launch. Settings, notes, onboarding completion, and credentials are not copied into or removed with the app bundle.

Users on 1.0.6 or older need one manual replacement to gain the updater. Quit On Air and replace the existing copy in Applications; deleting preferences or resetting permissions is not part of an update. Older development-signed copies can have a different macOS permission identity, so they are a separate migration case.

## Validation

- `Tools/test-core.sh`: persistent automatic-check preferences, existing settings, shared/duplicate checks, current/available/error results, start failure, and relaunch waiting across recording, transcription, pending Copy, and Retry.
- `Tools/test.sh`: the normal desktop/visual regression suite plus Settings/menu update actions, quiet discovery during dictation, deferred installation after paste, and deferred installation after Copy. Uses an isolated updater fixture with no network or real app installation. Run with the desktop unlocked; native keyboard/menu events cannot be validated at the lock screen.
- `python3 -m unittest discover -s Tools/ReleaseTests -v`: release metadata, nested signing order, missing framework/configuration, untrusted signing-tool downloads, feed identity/version/channel, checksum, and publication failures.
- `python3 Tools/check-update-signatures.py`: official pinned Sparkle tools with disposable random keys. Accepts valid files and rejects unsigned feeds, changed feed/archive bytes, and signatures from another key. No release key or Keychain access.
- Build Debug with `-derivedDataPath .build/updater-debug`, then run `python3 Tools/test-update-integration.py` separately from other desktop tests. This runs the production Sparkle adapter against a signed localhost feed in a disposable app: current version, available update, tampered feed, missing feed, and preference persistence across processes. Native Sparkle alerts are acknowledged only inside that test app. It never replaces the installed On Air, opens a microphone, or accesses the OpenAI key.
- Run the nonpublishing signed release workflow on the trusted implementation branch to exercise the actual framework/helper signing, Apple notarization, and final signed feed. A successful unsigned package or mocked signing test is not evidence of accepted notarization.

Before the first public updater release, exercise an actual upgrade between two signed Sparkle-enabled versions in a disposable installation. Verify replacement/relaunch, notes, glow, onboarding, Keychain access, and macOS permissions. The automated checks above do not claim to perform that final replacement or cover physical Intel hardware and every supported macOS version.

References: [Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/), [configuration](https://sparkle-project.org/documentation/customization/), [publishing updates](https://sparkle-project.org/documentation/).
