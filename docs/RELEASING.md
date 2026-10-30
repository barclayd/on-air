# Releasing On Air

The repository has three GitHub Actions workflows:

- **Build and package checks** runs on pull requests and pushes to main that change the app, Xcode project, app tests, packaging/test tools, or either app workflow. Website, documentation, and unrelated GitHub metadata changes skip this workflow. It can also be run manually. It runs release validation tests and real Sparkle signature checks, the audio/credential/clipboard core checks, builds both Mac architectures, verifies the compiled app icon is included, and creates an explicitly unsigned test DMG. It has read-only repository permissions and no signing secrets. The test DMG is not a distributable release.
- **Release On Air** runs on version tags or manually. It signs with Developer ID, notarizes and staples both the app and its DMG, checks Gatekeeper, and calculates the final checksum. Publishing uses a separate job with repository write permission and no Apple credentials.
- **Release On Air iOS Beta** is manual and exports an internal-only TestFlight build. Its separate `ios-beta` environment holds iPhone signing credentials; it cannot publish an App Store release or distribute to an external group.

All use the stable `macos-26` runner and Xcode 26.6. Action versions are pinned to reviewed commit hashes. The desktop E2E suite and macOS 27 visual baselines remain a separate `Tools/test.sh` check on a logged-in Mac; the hosted checks do not claim to replace those or physical microphone testing.

The automatic path filters live in `.github/workflows/ci.yml`; keep the pull-request and main-push lists in sync when adding app build inputs. Explicit version tags and manual runs remain deliberate build requests, regardless of changed paths. If branch protection is added, do not require this path-filtered workflow for every pull request: GitHub leaves required checks pending when a workflow is skipped by a path filter.

## Download links and release assets

Every signed release includes:

- `On-Air-vMAJOR.MINOR.PATCH.dmg` (including any prerelease suffix), for a particular version.
- `On-Air.dmg`, an identical copy with a stable filename for the website.
- A `.sha256` file for each DMG, plus `release.json` recording the version, source commit, build number, both filenames, and their shared checksum.
- `appcast.xml`, signed with the app’s Sparkle key, its `.sha256`, and `appcast_sha256` in the manifest (from the first Sparkle-enabled release onward).

The stable copy is made after signing, notarization, stapling, and Gatekeeper verification. Publication verifies both copies against the manifest and their own checksum files. Unsigned CI packages instead use `On-Air-unsigned.dmg` and cannot be published by the release workflow.

Use these links:

- [All versions and release notes](https://github.com/barclayd/on-air/releases).
- [Latest stable download](https://github.com/barclayd/on-air/releases/latest/download/On-Air.dmg), used by the website's Download for Mac button. This link starts working after the first stable release is published and follows future stable releases without a website update.
- A pinned version, for example `https://github.com/barclayd/on-air/releases/download/v1.0.0/On-Air-v1.0.0.dmg`, after that version is published.

Alpha, beta, and release-candidate downloads appear on their own release pages; they do not replace the latest stable download. Published older versions retain their own downloads. [GitHub's release-link documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).

## One-time Apple and GitHub setup

Obtain a **Developer ID Application** certificate for team `R2GGK3VN2C`, including its private key, and export it as a password-protected `.p12`. The existing Apple Development identity is not suitable. No provisioning profile is needed for this app's present capabilities.

Create an **App Store Connect team API key** with access to notarization. Keep the `.p8` private key, key ID, and issuer ID. This is an Apple credential, unrelated to the OpenAI key users supply for transcription. [Apple certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [notarization authentication](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

In the repository's **Settings → Environments**, create `release`. Add these secrets there:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of the exported Developer ID Application certificate and private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that P12 |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 of the Apple team API private key |
| `APPLE_NOTARY_KEY_ID` | Apple API key ID |
| `APPLE_NOTARY_ISSUER_ID` | Apple API issuer UUID |
| `SPARKLE_PRIVATE_KEY` | Sparkle Ed25519 private seed exported by the pinned `generate_keys` tool; already base64, do not encode it again |

Set repository or environment variable **`APPLE_TEAM_ID=R2GGK3VN2C`**. No OpenAI credential belongs in Actions; no build or regression check calls OpenAI. Restrict who can push release tags and who can use the release environment. If you configure environment deployment rules, allow `main` for manual previews and the intended `v*` tags for releases.

For the two file secrets, the GitHub CLI can accept base64 directly from a pipe without displaying the value:

```sh
base64 -i /path/to/developer-id.p12 | gh secret set APPLE_CERTIFICATE_P12_BASE64 --env release
base64 -i /path/to/AuthKey.p8 | gh secret set APPLE_NOTARY_KEY_P8_BASE64 --env release
```

Enter the other secrets in GitHub or through `gh secret set NAME --env release`, which prompts for a value. Do not paste secrets into issues, pull requests, or workflow source. The workflow imports signing material into an isolated temporary keychain and removes it, including on failures; it never exports a certificate from your Mac itself. [GitHub signing guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Validate the first signed build

After this workflow is merged and the credentials are configured:

1. Run `Tools/test.sh` on a logged-in Mac, including the existing app and visual regression tests.
2. In Actions → **Release On Air** → **Run workflow**, select `main`, enter a proposed version such as `v0.1.0-beta.1`, and leave **publish** unchecked. This builds the selected branch's exact workflow commit. A trusted release-maintainer branch can also be selected to validate pipeline fixes before merging, provided the `release` environment permits that branch. The version tag does not need to exist and is not created.
3. Download the `notarized-release` artifact. It contains both DMG filenames, their `.sha256` files, and `release.json` with the source commit, version, build number, and checksum. These preview artifacts are not public GitHub Releases downloads.
4. Test a browser-downloaded copy on a fresh Mac: Gatekeeper, copying to Applications, first launch, permissions, fn, microphone, transcription and paste. Test upgrading an older installation too. Check the oldest supported macOS and Intel hardware before advertising that support.

The pipeline validates a real unsigned archive and DMG without credentials in normal CI. A successful Developer ID signing/notarization run still needs the Apple credentials above; simulated failure tests do not prove Apple's service will accept the app.

## Publish a version

Choose a new version for each completed application change: patch for fixes,
minor for compatible features, and major for breaking changes. Keep both Xcode
configurations' `MARKETING_VERSION` aligned with that version. Each application
PR should include a signed, notarized preview built from its current commit using
the chosen tag with `publish=false`, plus validation evidence and a build link.
The preview does not create the tag or advance the public update feed.

Tags must be `vMAJOR.MINOR.PATCH`, or add `-alpha.N`, `-beta.N`, or `-rc.N` (N starts at 1). The tag must point to a commit on main. Tag a commit whose manual checks have passed:

```sh
git fetch origin
git tag v0.1.0-beta.1 <tested-commit-sha>
git push origin v0.1.0-beta.1
```

Pushing the tag automatically runs the signed workflow and publishes only after all verification succeeds. Alpha/beta/rc tags become GitHub prereleases; stable tags become the latest release. Public prereleases are public downloads.

A manual run with **publish** checked builds the existing version tag, requires it to be on main, and publishes it. It does not create tags. This is useful to retry a tag run after configuration is fixed. A manual run with **publish** unchecked builds the selected branch's exact workflow commit, even if the version label happens to match an older tag. Run previews only from trusted branches: they receive the Apple credentials from the `release` environment, although they cannot publish a GitHub release.

`CFBundleShortVersionString` uses the numeric version without a prerelease suffix. `CFBundleVersion` uses the release workflow's run number (1–9999). Each new run increments it; a rerun of the same run retains it. The Git tag and DMG filename retain the prerelease label.

Assets are assembled in a draft, then the complete release is published. Existing releases are never overwritten. If uploading fails and leaves a draft, inspect and remove that draft before rerunning; use a new version for any already-published build. Release diagnostics include archive and signing logs and Apple's notarization response and diagnostic log, retained for 14 days. Pending, rejected, malformed, or timed-out notarization results all block publication. Each Apple submission waits up to 20 minutes; an initial submission can require longer, in which case inspect its ID in the diagnostics before retrying.

## Local packaging checks

Python 3 and Xcode suffice; Xcode resolves the pinned Sparkle 2.10.0 package:

```sh
python3 -m unittest discover -s Tools/ReleaseTests -v
python3 Tools/release.py package --tag v0.1.0-beta.1 --build 2 --unsigned --output .build/package-check
```

Choose a fresh output directory per run. This exercises the actual universal archive, metadata checks, production-test isolation, drag-to-Applications DMG, and final checksum. It does not change the installed app, open a microphone, use credentials, or call Apple's notary service. It deliberately marks the artifact unpublishable.

The signed mode is the default and requires the same Apple environment variables as Actions. The app is notarized and stapled before DMG creation so its ticket travels with it after copying out of the image; the final DMG is then separately signed, notarized and stapled. Hashing occurs last. Sparkle update signing follows the final notarization and stapling steps; Homebrew remains optional. See [the updater](UPDATING.md).

## Sparkle signing and publication

The app pins Sparkle 2.10.0 through Swift Package Manager and commits `Package.resolved`. The release script downloads the matching official signing tools and verifies their pinned SHA-256 before extracting only `generate_appcast` and `sign_update`.

Keep the same Developer ID team and `com.danbarclay.onair` bundle identifier. Sign the embedded Downloader, Installer, Autoupdate, Updater app, and framework from the inside out, preserving their original entitlements. Sign the containing app last with its microphone entitlement. Verify the complete nested signature and notarize both app and DMG.

Only after the final DMG is stapled does `generate_appcast` produce its EdDSA signature and the signed feed. The build verifies both signatures, confirms the exact version/build, minimum OS, download URL, and channel, and hashes the feed. Publishing verifies these final hashes and uploads every asset into a draft before making it public. A failed build, signing operation, validation, or upload therefore cannot advance the public feed to an unavailable download.

The stable feed URL is `https://github.com/barclayd/on-air/releases/latest/download/appcast.xml`. Each enclosure points at an immutable versioned DMG. Stable releases advance both the website download and this feed together. Prereleases have a `beta` channel and never become GitHub's latest stable release. The initial implementation uses full downloads and disables delta generation.

The app-specific key was created with Sparkle's `generate_keys --account com.danbarclay.onair.sparkle`. Its public key is in `OnAir/Info.plist`; the private seed is in the maintainer's Keychain and the encrypted `release` environment secret. Keep an independent secure backup before changing machines. Export only to a temporary file with mode 0600, pipe it into `gh secret set SPARKLE_PRIVATE_KEY --env release`, then remove the export. Never commit or upload private keys as artifacts. Build subprocesses do not inherit the secret; signing tools receive it on stdin. Do not regenerate the key per release. Follow Sparkle's documented key-rotation procedure if rotation is necessary.

Because 1.0.6 and older do not contain an updater, users must replace the app manually once to install the first Sparkle-enabled version. Do not delete their preferences or Keychain entries. Thereafter Sparkle replaces the app in place and relaunches it after user confirmation. The final acceptance check before releasing the updater is an actual signed upgrade between two Sparkle-enabled versions on a disposable installation, including retained settings, Keychain access, permissions, and launch-at-login behavior if that feature is added later.


## Internal iPhone beta

Use the `OnAirPhone` scheme. App Store Connect must contain the iOS app
`com.danbarclay.onair.ios`. The keyboard and activity extensions use `.keyboard`
and `.activities`; all three need `group.com.danbarclay.onair.ios`. Keep the
version/build equal across the three targets. No OpenAI key is used during
packaging or stored in an artifact.

For the first beta, a signed-in local Xcode account can provision and upload:

```sh
python3 Tools/ios_beta.py --automatic --version 1.1.0 --build 2   --output .build/ios-beta-2 --upload
```

Commit tracked changes first. Choose a fresh output directory and unused build
number. The script verifies the archive and exported IPA signatures, team,
App Group, target versions and profile expiry, then writes `build.json` and the
IPA SHA-256. The export sets `testFlightInternalTestingOnly=true`; it is not an
App Store submission. Local upload uses the existing Xcode account. Its final
`uploaded` status means that processing and tester access still need checking
in App Store Connect.

If command-line export reports `No Accounts` while the account is available in
Xcode, open the same `.xcarchive` in Xcode Organizer and choose **Distribute App
→ TestFlight Internal Only**. Verify the bundle, version and build before upload,
then record the actual uploaded build and its processing status. This fallback
uses the existing signed-in account and does not require a new API credential.
The release checks also reject transparent iOS app icons before archiving.

After upload, follow that exact version/build through processing and compliance,
then add it to an internal group containing Dan's existing eligible App Store
Connect user. Confirm the group and build are available before giving TestFlight
installation instructions. Keep public links and external groups disabled.
Record the app/build IDs and source commit with the PR's build evidence. An
installed development build and an available TestFlight build are different
milestones; neither establishes real dictation acceptance without device checks.

For repeatable hosted distribution, configure the separate `ios-beta`
environment with restricted deployment branches/reviewers appropriate to the
repository. It needs these secrets, supplied by the account owner:

| Secret | Value |
| --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | Apple Distribution certificate and private key, exported as a password-protected P12 and base64 encoded |
| `IOS_DISTRIBUTION_PASSWORD` | P12 password |
| `IOS_APP_PROFILE_BASE64` | App Store distribution profile for the containing app |
| `IOS_KEYBOARD_PROFILE_BASE64` | App Store distribution profile for the keyboard |
| `IOS_ACTIVITY_PROFILE_BASE64` | App Store distribution profile for the activity extension |
| `APP_STORE_CONNECT_KEY_P8_BASE64` | Team API key authorised for uploading builds and managing the intended internal group |
| `APP_STORE_CONNECT_KEY_ID` | API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Team issuer ID |

Set environment variables `APP_STORE_CONNECT_APP_ID` and `IOS_INTERNAL_GROUP_ID`
to the confirmed app and internal group. Do not assume the Mac notarisation key
has these permissions. The initial beta does not require exporting or replacing
local signing credentials: use the local account route while CI setup is pending.

Once the workflow exists on the default branch, dispatch **Release On Air iOS
Beta** on the intended trusted branch. It uses build number
`run_number * 100 + run_attempt` (local builds 1–100 are reserved), rejects an
existing version/build, verifies the group belongs to this app and is internal,
and waits up to 30 minutes for processing before assigning that build. It reports
`assigned-internal-group` only after reading the assignment back. If Apple is
still processing, follow that build rather than uploading a duplicate. The
14-day Actions artifact contains the IPA, hashes, manifest and diagnostic logs;
signing credentials stay in temporary files/keychain and are cleaned up.

The workflow's presence does not mean its environment or credentials have been
configured. Check those separately before attempting hosted distribution.
