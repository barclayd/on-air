# Onboarding design fidelity

Reference: the supplied **On Air Onboarding-2.html** (4 October 2026).

The native window uses the reference’s 540 × 500 composition, 44-point side margins, header at 60 points, permission card and 40 × 24 switches, compact key screen, and centred ready state. Permission icons reproduce the reference’s SVG paths. The completion Canvas follows its red glow, travelling blue line, ascent, and checkmark morph, settling after approximately five seconds. Reduce Motion presents the final state immediately.

The browser export includes a 1 px outside border and a surrounding presentation backdrop. macOS draws the real window border, corners, shadow, and traffic-light controls; these vary by OS and activation state. They are not painted imitations of the HTML’s decorative dots. An AppKit container prevents SwiftUI from adding an extra title-bar-height strip to the window.

## Necessary production differences

- **Permissions:** the switches request access or open the corresponding System Settings pane. They reflect actual permission status; clicking cannot directly grant or revoke macOS access. Denial, restriction, and failed navigation add contextual help only when needed.
- **Essential permissions only:** the third row is removed. Accessibility already covers the existing global key monitor. The fn / Globe action does not need to be changed or confirmed; legacy confirmation values are ignored.
- **Verification:** the HTML accepts a key-shaped string. The app verifies a real transcription session and saves successful credentials to Keychain. Failures stay editable and show an inline error. No microphone capture is involved.
- **Saved credentials:** a saved key is verified automatically, then setup advances. A failed stored key can be retried or removed so another can be entered. No repeat confirmation or extra footer is added.
- **Notes:** optional dictation notes are omitted from onboarding under the latest essential-only scope. They remain editable in Settings with the generic placeholder; existing saved notes are preserved. Optional edits never gate setup completion.
- **Completion:** Done closes setup and remembers completion. The HTML’s Done resets its demonstration. Its clickable keycap and Space-key demo do not become alternate recording controls: only physical fn hold/release starts and ends dictation.

## Interaction and regression checks

Already-granted permissions are skipped on opening setup. Newly granted permissions advance after 650 ms; successful key verification advances after 700 ms, including saved keys. Closing setup, revoking a permission, or removing a key cancels pending navigation.

App-process tests assert the outer window dimensions and capture proportions, exercise automatic transitions and persistence, and capture each screen for visual inspection. Model checks cover navigation cancellation, permission/key revocation, optional Settings isolation, and absent/false/true legacy fn confirmations. The original native layouts were compared with the HTML; the essential-only revision intentionally omits the optional controls. Updated native screenshots are also checked; captures are inspection evidence, not cross-platform pixel baselines.
