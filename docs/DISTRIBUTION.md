# Distribution recommendation

Researched 3 October 2026. The release workflow is now implemented; see [Releasing On Air](RELEASING.md) for configuration and operation. Signing credentials are still required. No binary release, updater, or setup UI has been published or added.

**Start with a Developer ID-signed, Apple-notarized DMG on GitHub Releases.** Use manual downloads for the first tester group. Add Sparkle 2 updates before expanding to a broad audience, and optionally add a Homebrew cask later. This fits On Air's existing native, unsandboxed architecture and avoids an application backend.

## Channel choice

| Route | Recommendation | Reason |
| --- | --- | --- |
| Direct DMG download | Primary route | Familiar drag-to-Applications installation and compatible with On Air's current permissions and architecture. |
| GitHub Releases | Initial download host | Existing public repository; versioned assets and release notes. A website can link to the same downloads later. |
| Homebrew cask | Optional later | Useful for developers; adds a maintenance obligation and assumes Homebrew is installed. |
| Mac App Store | Poor fit for this implementation | Store distribution requires App Sandbox; On Air inspects the focused field in other apps through Accessibility. |
| Installer package | Unnecessary initially | On Air is a self-contained app bundle without privileged helpers or system components to install. |

Apple lists assistive use of Accessibility APIs as incompatible with App Sandbox, and requires sandboxing for Store apps. The channel recommendation follows from those restrictions and On Air's code; microphone access alone is not the blocker. [Apple sandbox documentation](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), [App Review guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility).

GitHub supports uploaded release binaries and release notes. Each asset must be under 2 GiB; its documentation specifies no total release-size or bandwidth limit. Public prereleases are still public, so a genuinely private beta would need access-controlled hosting. [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).

## What is ready, and what is missing

The repository already builds a universal arm64/x86_64 app with a macOS 14 deployment target, Hardened Runtime, and the microphone entitlement. The tested hardware is Apple silicon running macOS 27; the deployment target and Intel slice do not prove compatibility on every supported Mac.

The current local identity is **Apple Development**. No valid **Developer ID Application** identity was found in the Mac's current signing-identity search. This does not establish whether the Apple account already has an active paid membership or a certificate available elsewhere.

Public distribution needs a Developer ID Application certificate and notarization. Apple's process also requires Hardened Runtime and a secure signing timestamp. Development signing is not a substitute. Apple Developer Program membership is **US$99/year or local pricing**, if not already held. [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [membership pricing](https://developer.apple.com/programs/enroll/).

Before a general release, I recommend:

- A small way to enter, replace, and remove the user's own API key, keeping Keychain storage. The current `~/.env` import is suitable for this development setup or technical testers, but awkward for ordinary users. Never bundle the developer's key.
- Concise setup guidance for Microphone, Accessibility, and the Globe-key setting. This is a future product decision: the user's earlier request to defer setup UI remains respected in the current build.
- An app icon. The pipeline now sets version/build numbers and generates release notes; no app-icon asset currently exists.
- A clear explanation that speech is sent to OpenAI and recordings are retained only temporarily by the app. Local memory-only handling should not be described as a guarantee about the provider's retention.
- Fresh-install and upgrade checks in Codex, Chrome, and Slack, plus tests on the oldest macOS and Intel hardware we intend to advertise. Verify permission and Keychain behavior when moving from development signing to Developer ID signing.

## First release workflow

1. Run the regression suite, then archive and export a Release build using Developer ID Application signing. Keep the established bundle identifier and team stable.
2. Package `On Air.app` in a read-only DMG with an Applications shortcut. Sign the deliverable with a secure timestamp.
3. Submit the final artifact to Apple's notarization service using `notarytool`, inspect the result, and staple and validate the ticket. Verify code signing and Gatekeeper acceptance.
4. Download the artifact through a browser onto a clean test Mac or VM. Test installation and first launch, then real microphone/fn/paste behavior on physical hardware. Also test replacement of an older installed version.
5. Publish a versioned GitHub prerelease with the DMG, SHA-256 checksum, supported systems, setup instructions, known limitations, and release notes. Promote a tested build to the stable channel.

Apple documents DMG packaging and notarization as supported direct-distribution workflows. Notarization is an automated security check, not App Store review. [Packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution), [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The release script and GitHub Actions workflow use an isolated temporary keychain and environment secrets for signing and notarization credentials. Keep release credentials out of pull-request jobs. The existing UI tests require a logged-in GUI session, so retain a suitable Mac test runner instead of assuming every hosted runner supports them. [GitHub's macOS signing workflow](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Updates and optional channels

**Sparkle 2 is the recommended updater once there are regular external users.** It supports SwiftUI integration and DMG updates. Serve the feed and downloads over HTTPS, sign update archives with its Ed25519 key, and retain Apple signing/notarization. Its appcast is a static feed, so the update service need not introduce user accounts or an application server. This would be an explicit exception to the original zero-dependency preference; keep manual replacement for the first release if that constraint still takes priority. [Sparkle documentation](https://sparkle-project.org/documentation/).

A Homebrew cask can later point to the same versioned DMG and checksum. Use an upstream tap initially; acceptance into the central cask repository is a separate review with eligibility requirements. It supplements the normal download, rather than becoming a prerequisite. [Homebrew taps](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap), [cask acceptance](https://docs.brew.sh/Acceptable-Casks).

The next concrete milestone is a notarized DMG for a small tester group. It requires configuring the distribution signing identity and notarization credentials, then running the pipeline and a fresh-install check. A broad release should additionally resolve API-key setup and permission guidance.
