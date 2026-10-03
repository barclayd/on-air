# Releasing On Air

The repository has two GitHub Actions workflows:

- **Build and package checks** runs on pull requests and pushes to main that change the app, Xcode project, app tests, packaging/test tools, or either app workflow. Website, documentation, and unrelated GitHub metadata changes skip this workflow. It can also be run manually. It runs ten release tests, the audio/credential/clipboard core checks, builds both Mac architectures, and creates an explicitly unsigned test DMG. It has read-only repository permissions and no signing secrets. The test DMG is not a distributable release.
- **Release On Air** runs on version tags or manually. It signs with Developer ID, notarizes and staples both the app and its DMG, checks Gatekeeper, and calculates the final checksum. Publishing uses a separate job with repository write permission and no Apple credentials.

Both use the stable `macos-26` runner and Xcode 26.6. Action versions are pinned to reviewed commit hashes. The desktop E2E suite and macOS 27 visual baselines remain a separate `Tools/test.sh` check on a logged-in Mac; the hosted checks do not claim to replace those or physical microphone testing.

The automatic path filters live in `.github/workflows/ci.yml`; keep the pull-request and main-push lists in sync when adding app build inputs. Explicit version tags and manual runs remain deliberate build requests, regardless of changed paths. If branch protection is added, do not require this path-filtered workflow for every pull request: GitHub leaves required checks pending when a workflow is skipped by a path filter.

## Download links and release assets

Every signed release includes:

- `On-Air-vMAJOR.MINOR.PATCH.dmg` (including any prerelease suffix), for a particular version.
- `On-Air.dmg`, an identical copy with a stable filename for the website.
- A `.sha256` file for each DMG, plus `release.json` recording the version, source commit, build number, both filenames, and their shared checksum.

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

Python 3 and Xcode suffice; the app gains no runtime dependencies:

```sh
python3 -m unittest discover -s Tools/ReleaseTests -v
python3 Tools/release.py package --tag v0.1.0-beta.1 --build 2 --unsigned --output .build/package-check
```

Choose a fresh output directory per run. This exercises the actual universal archive, metadata checks, production-test isolation, drag-to-Applications DMG, and final checksum. It does not change the installed app, open a microphone, use credentials, or call Apple's notary service. It deliberately marks the artifact unpublishable.

The signed mode is the default and requires the same Apple environment variables as Actions. The app is notarized and stapled before DMG creation so its ticket travels with it after copying out of the image; the final DMG is then separately signed, notarized and stapled. Hashing occurs last. Sparkle and Homebrew remain future steps described in [the distribution plan](DISTRIBUTION.md).
