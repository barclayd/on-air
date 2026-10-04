# Onboarding design fidelity

Reference: the supplied **On Air Onboarding-2.html** (4 October 2026).

The native window uses the reference’s 540 × 500 composition, 44-point side margins, header at 60 points, permission card and 40 × 24 switches, compact notes/key screen, and centred ready state. Permission icons reproduce the reference’s SVG paths. The completion Canvas follows its red glow, travelling blue line, ascent, and checkmark morph, settling after approximately five seconds. Reduce Motion presents the final state immediately.

The browser export includes a 1 px outside border and a surrounding presentation backdrop. macOS draws the real window border, corners, shadow, and traffic-light controls; these vary by OS and activation state. They are not painted imitations of the HTML’s decorative dots. An AppKit container prevents SwiftUI from adding an extra title-bar-height strip to the window.

## Necessary production differences

- **Permissions:** the switches request access or open the corresponding System Settings pane. They reflect actual permission status; clicking cannot directly grant or revoke macOS access. Denial, restriction, and failed navigation add contextual help only when needed.
- **Third row:** `fn / Globe key` replaces `Input Monitoring`. The app’s existing global key monitor uses Accessibility trust. Keyboard settings must be set to **Do Nothing**; a popover collects explicit user confirmation because macOS provides no public API for checking that preference.
- **Verification:** the HTML accepts a key-shaped string. The app verifies a real transcription session and saves successful credentials to Keychain. Failures stay editable and show an inline error. No microphone capture is involved.
- **Saved credentials:** a returning user gets **Continue** in the Verify button’s position and can remove a masked stored key. This state is absent from the mockup. It keeps notes available for review. No extra footer is added.
- **Notes:** the previously requested generic placeholder is retained. Valid edits, including clearing notes, persist immediately and appear in Settings. Invalid edits show an inline error and block completion.
- **Completion:** Done closes setup and remembers completion. The HTML’s Done resets its demonstration. Its clickable keycap and Space-key demo do not become alternate recording controls: only physical fn hold/release starts and ends dictation.

## Interaction and regression checks

Permissions advance after 650 ms of readiness. An explicit new-key verification advances after 700 ms of success. Editing notes pauses this transition and exposes Continue. Closing setup or losing a prerequisite cancels pending navigation. Reopening with a saved key never skips the notes screen.

App-process tests assert the outer window dimensions and capture proportions, exercise automatic transitions and persistence, and capture each screen for visual inspection. Model checks cover navigation cancellation, permission revocation, and notes-focus races. Native and browser screenshots were compared for all three states; captures are inspection evidence, not cross-platform pixel baselines.
