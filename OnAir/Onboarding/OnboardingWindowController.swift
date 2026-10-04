import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    private let controller: PrototypeController

    init(model: OnboardingModel, controller: PrototypeController) {
        self.model = model
        self.controller = controller
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
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
            let content = NSHostingView(rootView: OnboardingView(model: model, controller: controller, onDone: { [weak self] in
                guard let self, self.model.finish() else { return }
                self.close()
            }))
            // Include native title-bar chrome in the design's outer dimensions.
            // NSHostingView otherwise adds the title-bar safe area to its ideal height.
            content.sizingOptions = []
            content.safeAreaRegions = []
            // An AppKit container owns the outer geometry. Hosting directly as the
            // content view lets SwiftUI add a title-bar-height strip on macOS 27.
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 500))
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)
            window.contentView = container
            window.setFrame(NSRect(x: 0, y: 0, width: 540, height: 500), display: false)
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
