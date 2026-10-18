import AppKit
import CryptoKit

/// Launched only inside a disposable test bundle with a localhost feed and an
/// ephemeral signing key. Uses the production Sparkle adapter and native driver.
@main struct UpdateIntegrationChecks {
    @MainActor static func main() throws {
        let mode = CommandLine.arguments[1]
        if mode == "public-key" {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let seed = Data(base64Encoded: input)!
            print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if mode == "background-available" {
            UserDefaults.standard.set(true, forKey: "SUEnableAutomaticChecks")
            UserDefaults.standard.removeObject(forKey: "SULastCheckTime")
        }
        let model = UpdateModel(driver: SparkleUpdateDriver(), dictationIsBusy: { false })
        model.start()
        guard model.canCheck else { fatalError("Real Sparkle updater did not start") }
        if mode == "preferences-write" {
            UserDefaults.standard.set("Keep my vocabulary", forKey: "dictationNotes")
            UserDefaults.standard.set(0.3, forKey: "recordingGlowIntensity")
            UserDefaults.standard.set(true, forKey: "onboarding.completed.v1")
            model.setAutomaticallyChecks(true)
            model.setAutomaticallyChecks(false)
            UserDefaults.standard.synchronize()
            print("PASS: real Sparkle preference written")
            return
        }
        if mode == "preferences-read" {
            guard !model.automaticallyChecks,
                  UserDefaults.standard.string(forKey: "dictationNotes") == "Keep my vocabulary",
                  UserDefaults.standard.double(forKey: "recordingGlowIntensity") == 0.3,
                  UserDefaults.standard.bool(forKey: "onboarding.completed.v1") else {
                fatalError("Settings did not survive relaunch")
            }
            print("PASS: real Sparkle preference and existing settings survive relaunch")
            return
        }
        let deadline = Date().addingTimeInterval(20)
        var openedReminder = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if mode == "background-available", case .available = model.status, model.canCheck {
                    let updateWindows = app.windows.filter { window in
                        window.contentView.flatMap { button(named: "Install Update", in: $0) } != nil
                    }
                    if !openedReminder {
                        guard !updateWindows.contains(where: \.isVisible) else {
                            print("Background discovery unexpectedly opened an update window"); exit(1)
                        }
                        openedReminder = true
                        model.check()
                        model.check()
                    } else if updateWindows.filter(\.isVisible).count == 1 {
                        print("PASS: background reminder opens one native installation window after the manual check action")
                        exit(0)
                    }
                }
                // Sparkle's native no-update/error alert runs a modal event loop.
                // Dismiss only Sparkle's acknowledgement buttons in this disposable app.
                if let button = app.windows.lazy.compactMap({ $0.contentView.flatMap(okButton) }).first {
                    button.performClick(nil)
                }
                let result: String? = switch model.status {
                case .upToDate: "current"
                case .available: "available"
                case .failed: "error"
                default: nil
                }
                if let result, mode != "background-available" {
                    guard result == mode else { print("Unexpected Sparkle result: \(result), expected \(mode)"); exit(1) }
                    if result == "available" && !app.windows.contains(where: { $0.isVisible && $0.contentView.flatMap { button(named: "Install Update", in: $0) } != nil }) {
                        if Date() >= deadline { print("Update found but its installation window never appeared"); exit(1) }
                        return
                    }
                    print("PASS: real Sparkle \(mode) callback")
                    exit(0)
                }
                if Date() >= deadline { print("Sparkle check timed out"); exit(1) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        if mode != "background-available" { model.check() }
        app.run()
    }

    @MainActor private static func okButton(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton, ["OK", "Cancel Update"].contains(button.title) { return button }
        return view.subviews.lazy.compactMap(okButton).first
    }

    @MainActor private static func button(named title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(named: title, in: $0) }.first
    }
}
