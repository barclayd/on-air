import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class OverlayWindowController {
    private var panel: OverlayPanel?

    @discardableResult
    func show(controller: PrototypeController) -> Bool {
        guard let screen = destinationScreen() else { return false }
        if panel == nil {
            let panel = OverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            panel.contentView = NSHostingView(rootView: GlowView(controller: controller))
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            self.panel = panel
        }
        // Capture the destination once per hold; never chase the pointer or steal keyboard focus.
        panel?.setFrame(screen.frame, display: true)
        panel?.orderFrontRegardless()
        return true
    }

    func hide() { panel?.orderOut(nil) }
    func reshow() { panel?.orderFrontRegardless() }

    private func destinationScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let application = NSWorkspace.shared.frontmostApplication {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = unsafeDowncast(value, to: AXUIElement.self)
                if let bounds = bounds(of: window), let screen = bestScreen(for: bounds, screens: screens) {
                    return screen
                }
            }
        }
        // NSScreen.main is the keyboard-focus screen, not necessarily the primary display.
        return NSScreen.main ?? screens.first
    }

    private func bounds(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func bestScreen(for axBounds: CGRect, screens: [NSScreen]) -> NSScreen? {
        // Accessibility has a top-left origin; AppKit has a bottom-left origin on the primary screen.
        let primaryHeight = screens.first?.frame.height ?? 0
        let appKitBounds = CGRect(
            x: axBounds.minX, y: primaryHeight - axBounds.maxY,
            width: axBounds.width, height: axBounds.height
        )
        let best = screens.max { lhs, rhs in
            area(lhs.frame.intersection(appKitBounds)) < area(rhs.frame.intersection(appKitBounds))
        }
        guard let best, area(best.frame.intersection(appKitBounds)) > 0 else { return nil }
        return best
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
