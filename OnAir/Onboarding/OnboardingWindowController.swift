import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel

    init(model: OnboardingModel) {
        self.model = model
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("on-air.onboarding")
            window.title = "Set up On Air"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(calibratedRed: 29 / 255, green: 28 / 255, blue: 27 / 255, alpha: 1)
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(model: model, onDone: { [weak self] in
                guard let self, self.model.finish() else { return }
                self.close()
            }))
            window.center()
            self.window = window
        }
        model.appear()
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
    func windowWillClose(_ notification: Notification) {
        model.disappear()
        AppWindowLifecycle.didClose(window)
    }
}

/// Settings and setup can coexist without one closing the other's application menu.
@MainActor
enum AppWindowLifecycle {
    static func didClose(_ closing: NSWindow?) {
        let hasOtherWindow = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && ["on-air.settings", "on-air.onboarding"].contains($0.identifier?.rawValue ?? "")
        }
        if !hasOtherWindow { NSApp.setActivationPolicy(.accessory) }
    }
}
