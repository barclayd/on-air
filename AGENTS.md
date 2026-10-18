# On Air repository workflow

For completed application changes, automatically prepare a pull request and a
signed, notarized build. The user does not need to request those steps again.

- Choose the version based on the latest published release and the changes:
  increment the patch for fixes, the minor for new compatible features, and the
  major for breaking changes. Check existing releases and pending versioned PRs
  before choosing an unused version.
- Keep `MARKETING_VERSION` in both Xcode configurations aligned with the chosen
  version. Release builds get their increasing `CFBundleVersion` from the release
  workflow run number; do not reuse a published version for changed binaries.
- Run the relevant checks, then create or update the PR with the resulting
  behavior, version, validation evidence, and any remaining test limitations.
- Run **Release On Air** from the PR branch with the chosen version tag and
  `publish=false`. Verify the completed artifact's version, source commit,
  checksums, signing, and notarization, then link the build from the PR.
- Keep preview builds unpublished while the PR is open. Release tags must point
  to tested commits on main. Follow [docs/RELEASING.md](docs/RELEASING.md) for
  publication and [docs/TESTING.md](docs/TESTING.md) for appropriate checks.

Preserve the existing interface unless a UI change is requested. Keep local
dictation diagnostics private and exclude dictated text, field/clipboard contents,
window titles, and credentials from logs and PR evidence.
