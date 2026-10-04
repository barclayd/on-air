import AppKit
import SwiftUI

@main
struct OnAirApp: App {
    @NSApplicationDelegateAdaptor(OnAirDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            OnAirMenu(controller: delegate.controller, openSetup: delegate.showSetup)
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
    let openSetup: () -> Void
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
        Button("Set up On Air…", action: openSetup)
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
    lazy var onboarding = bridge.makeOnboarding(settings: settings, controller: controller)
    #else
    let controller = PrototypeController()
    lazy var settings = SettingsModel(glow: controller.glow, didChange: { [weak self] in self?.controller.settingsDidChange() })
    lazy var onboarding = OnboardingWindowController(model: OnboardingModel(settings: settings), controller: controller)
    #endif

    func showSetup() { onboarding.present() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        #if E2E_TESTING
        _ = onboarding
        bridge.start(controller: controller)
        if bridge.shouldShowOnboarding { showSetup() }
        #else
        controller.start()
        if onboarding.model.shouldPresentOnLaunch { showSetup() }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        onboarding.model.disappear()
        controller.stop()
        #if E2E_TESTING
        bridge.didStop(controller: controller)
        #endif
    }
}
