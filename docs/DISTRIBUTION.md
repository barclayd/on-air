# Distribution

Updated 18 October 2026. On Air 1.0.6 is publicly released as a universal Developer ID-signed, notarized DMG. Setup, API-key management, the app icon, and the release pipeline are implemented. Sparkle 2 integration is the next release change; see [updater behavior](UPDATING.md) and [release operations](RELEASING.md).

The primary route remains the [website download](https://github.com/barclayd/on-air/releases/latest/download/On-Air.dmg) backed by GitHub Releases. Downloaded apps keep the bundle identifier `com.danbarclay.onair` and Developer ID team `R2GGK3VN2C`. Settings live outside the app bundle in UserDefaults; the user's OpenAI key remains in the existing Keychain service. Replacing an app must not remove either.

Sparkle 2 provides the native check, download, install, and relaunch flow without an application backend. Signed static appcasts and immutable versioned DMGs are published together. Full downloads are sufficient for this small application; deltas can be considered if measured download sizes justify the extra release complexity. [Sparkle documentation](https://sparkle-project.org/documentation/).

Direct distribution suits the app's existing unsandboxed Accessibility integration. The Mac App Store would require a separate sandbox-compatible design; it is not part of this change. [Apple sandbox documentation](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox).

Homebrew can be added later as a supplementary channel. It is not a prerequisite for installing or updating On Air. [Homebrew cask documentation](https://docs.brew.sh/Cask-Cookbook).

The deployment target remains macOS 14 with both Intel and Apple silicon binaries. Local desktop automation runs on Apple silicon/macOS 27, while hosted packaging uses macOS 26. Test real upgrades on the oldest supported macOS and Intel hardware before claiming those paths have been exercised. Moving from older development-signed copies to Developer ID may require macOS permissions to be granted again; the normal release-to-release path keeps the same signing identity.
