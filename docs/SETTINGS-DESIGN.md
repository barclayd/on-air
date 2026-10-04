# Settings design parity

Reference: the supplied `On Air Settings-2.html` (4 October 2026). The attachment is design reference data; its simulated verification logic and example credentials are not application behaviour.

The native Settings window keeps the 520-point width, 32-point horizontal padding, 30-point section gaps, thin dividers, warm dark palette, 14-point semibold headings, 13-point explanatory text and 10-point field corners. Notes retain the four-line height and inset text. Draft, verifying, rejected and stored-key states keep real validation and Keychain persistence while using the reference’s field, button and status colours.

Glow intensity uses the reference’s percentage readout, 4-point gradient track, subtle red halo, round 18-point thumb and Subtle/Bright labels. An AppKit slider uses pointer events matched to the custom thumb, with native keyboard navigation and accessibility; arrow keys and accessibility actions move through the existing eleven calibrated levels. The retained preview sits below the labels and uses no microphone. Focus/drag adds the reference’s red thumb ring.

Deliberate adaptations:
- Window buttons, outer shadow and corner treatment remain macOS-managed. The toolbar’s native height is compensated in the content padding to align the body with the reference’s 52-point header.
- The web page’s surrounding backdrop is presentation staging, not part of the app window. The approved inline preview supplies the glow demonstration instead of a second temporary wash over the whole window.
- The existing generic dictation-notes placeholder is retained.
- The agreed faint minimum is labelled 0%, not Off. The existing default remains 50%, and existing saved preferences are retained; the HTML’s 60% is a demonstration state.
- Setup remains accessible from the menu bar. The extra Settings footer link is removed to match the reference.

The reference and native empty, rejected and verified states were inspected visually. Settings tests exercise the actual native window and slider (dragging, keyboard and accessibility), not a reimplementation of the model in the test runner.
