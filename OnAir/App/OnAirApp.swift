import AppKit
import SwiftUI

@main
struct OnAirApp: App {
    @NSApplicationDelegateAdaptor(OnAirDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            OnAirMenu(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.isListening ? "record.circle.fill" : delegate.controller.isTranscribing ? "ellipsis" : "waveform")
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("On Air — \(delegate.controller.statusText)")
        }
        Settings {
            SettingsView(model: delegate.settings)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
    }
}

private struct OnAirMenu: View {
    let controller: PrototypeController
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text(controller.statusText)
        if controller.pendingTranscript != nil {
            Button("Copy transcript") { controller.copyTranscript() }
        }
        if controller.canRetry {
            Button("Retry transcription") { controller.retryTranscription() }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit On Air") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class OnAirDelegate: NSObject, NSApplicationDelegate {
    #if E2E_TESTING
    private let bridge = EndToEndBridge()
    lazy var controller = bridge.makeController()
    lazy var settings = bridge.makeSettings(controller: controller)
    #else
    let controller = PrototypeController()
    lazy var settings = SettingsModel(didChange: { [weak self] in self?.controller.settingsDidChange() })
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        #if E2E_TESTING
        bridge.start(controller: controller)
        #else
        controller.start()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        #if E2E_TESTING
        bridge.didStop(controller: controller)
        #endif
    }
}
