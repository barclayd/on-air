import AppKit
import AVFoundation
import Observation
@preconcurrency import ApplicationServices

enum SetupPane: String {
    case microphone, accessibility, keyboard

    var settingsTitle: String {
        switch self {
        case .microphone: "Microphone"
        case .keyboard: "Keyboard"
        case .accessibility:
            if #available(macOS 27.0, *) { "Device Control and Data Access" }
            else { "Accessibility" }
        }
    }

    var url: URL {
        let destination = switch self {
        case .microphone: "com.apple.preference.security?Privacy_Microphone"
        case .accessibility: "com.apple.preference.security?Privacy_Accessibility"
        case .keyboard: "com.apple.Keyboard-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:\(destination)")!
    }
}

/// These operations never record audio or change a macOS preference for the user.
@MainActor
protocol SetupSystemAccess {
    var microphoneStatus: AVAuthorizationStatus { get }
    var accessibilityTrusted: Bool { get }
    func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void)
    func requestAccessibility()
    func open(_ pane: SetupPane) -> Bool
}

struct MacSetupSystemAccess: SetupSystemAccess {
    var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    func open(_ pane: SetupPane) -> Bool { NSWorkspace.shared.open(pane.url) }
}

@MainActor
@Observable
final class OnboardingModel {
    enum Step: String { case permissions, connection, ready }
    static let completionKey = "onboarding.completed.v1"
    static let globeConfirmationKey = "onboarding.globeConfirmed.v1"

    let settings: SettingsModel
    private(set) var step: Step = .permissions
    private(set) var microphone: AVAuthorizationStatus = .notDetermined
    private(set) var accessibility = false
    private(set) var requestingMicrophone = false
    private(set) var globeConfirmed: Bool
    private(set) var showsKeyboardInstructions = false
    private(set) var showsAccessibilityInstructions = false
    private(set) var notice: String?
    private(set) var completed: Bool
    @ObservationIgnored private let system: any SetupSystemAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var promptedAccessibility = false

    init(settings: SettingsModel, system: any SetupSystemAccess = MacSetupSystemAccess(), defaults: UserDefaults = .standard) {
        self.settings = settings
        self.system = system
        self.defaults = defaults
        globeConfirmed = defaults.bool(forKey: Self.globeConfirmationKey)
        completed = defaults.bool(forKey: Self.completionKey)
        refresh()
    }

    var permissionsReady: Bool { microphone == .authorized && accessibility && globeConfirmed }
    var ready: Bool { permissionsReady && settings.verified && settings.maskedKey != nil && !settings.verifying }
    var shouldPresentOnLaunch: Bool { !completed || !permissionsReady || !settings.hasSavedKey }

    func appear() {
        settings.present(owner: "onboarding")
        refresh()
        if completed && permissionsReady { step = .connection }
        reconcile()
        guard poll == nil else { return }
        // Poll only while setup is open, including while System Settings is frontmost.
        // Merely returning from Settings is never treated as consent.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        poll = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func disappear() {
        poll?.invalidate()
        poll = nil
        settings.dismiss(owner: "onboarding")
    }

    func refresh() {
        microphone = system.microphoneStatus
        accessibility = system.accessibilityTrusted
        reconcile()
    }

    func reconcile() {
        if step != .permissions && !permissionsReady { step = .permissions }
        if step == .ready && !ready { step = .connection }
        if step == .connection && ready { step = .ready }
    }

    func enableMicrophone() {
        refresh()
        notice = nil
        switch microphone {
        case .notDetermined:
            guard !requestingMicrophone else { return }
            requestingMicrophone = true
            system.requestMicrophone { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.requestingMicrophone = false
                    self.refresh() // Read the system, not the callback's cached answer.
                }
            }
        case .denied, .authorized: open(.microphone)
        case .restricted: notice = "Microphone access is restricted on this Mac. Ask your administrator to allow it."
        @unknown default: notice = "Microphone access is unavailable. Check Privacy & Security in System Settings."
        }
    }

    func enableAccessibility() {
        refresh()
        showsAccessibilityInstructions = !accessibility
        if !accessibility && !promptedAccessibility {
            promptedAccessibility = true
            system.requestAccessibility()
        }
        open(.accessibility)
        refresh()
    }

    func configureKeyboard() {
        showsKeyboardInstructions = true
        open(.keyboard)
    }

    func confirmGlobeSetting(_ confirmed: Bool) {
        // macOS has no public API for this preference. Keep this user confirmation
        // distinct from the permissions we can verify with system APIs.
        globeConfirmed = confirmed
        defaults.set(confirmed, forKey: Self.globeConfirmationKey)
        reconcile()
    }

    func continueSetup() {
        refresh()
        guard permissionsReady else { return }
        step = ready ? .ready : .connection
    }

    func back() { step = .permissions }

    @discardableResult func finish() -> Bool {
        refresh()
        guard step == .ready, ready else { return false }
        completed = true
        defaults.set(true, forKey: Self.completionKey)
        return true
    }

    private func open(_ pane: SetupPane) {
        notice = nil
        if !system.open(pane) {
            notice = "Couldn’t open System Settings. Open it from the Apple menu, then choose \(pane == .keyboard ? pane.settingsTitle : "Privacy & Security → " + pane.settingsTitle)."
        }
    }
}
