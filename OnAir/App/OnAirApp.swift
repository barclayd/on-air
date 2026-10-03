import AppKit
import SwiftUI

@main
struct OnAirApp: App {
    @NSApplicationDelegateAdaptor(OnAirDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Text(delegate.controller.statusText)
            if delegate.controller.pendingTranscript != nil {
                Button("Copy transcript") { delegate.controller.copyTranscript() }
            }
            if delegate.controller.canRetry {
                Button("Retry transcription") { delegate.controller.retryTranscription() }
            }
            Divider()
            Button("Quit On Air") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: delegate.controller.isListening ? "record.circle.fill" : delegate.controller.isTranscribing ? "ellipsis" : "waveform")
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("On Air — \(delegate.controller.statusText)")
        }
    }
}

@MainActor
final class OnAirDelegate: NSObject, NSApplicationDelegate {
    #if E2E_TESTING
    private let bridge = EndToEndBridge()
    lazy var controller = bridge.makeController()
    #else
    let controller = PrototypeController()
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
