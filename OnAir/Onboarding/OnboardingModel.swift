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
    private(set) var verificationRequested = false
    private(set) var editingNotes = false
    @ObservationIgnored private let system: any SetupSystemAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var promptedAccessibility = false
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var transitionTarget: Step?
    @ObservationIgnored private var presented = false

    init(settings: SettingsModel, system: any SetupSystemAccess = MacSetupSystemAccess(), defaults: UserDefaults = .standard) {
        self.settings = settings
        self.system = system
        self.defaults = defaults
        globeConfirmed = defaults.bool(forKey: Self.globeConfirmationKey)
        completed = defaults.bool(forKey: Self.completionKey)
        refresh()
    }

    var permissionsReady: Bool { microphone == .authorized && accessibility && globeConfirmed }
    var ready: Bool {
        permissionsReady && settings.verified && settings.maskedKey != nil &&
        !settings.verifying && settings.notesError == nil
    }
    var shouldPresentOnLaunch: Bool { !completed || !permissionsReady || !settings.hasSavedKey }

    func appear() {
        presented = true
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
        presented = false
        verificationRequested = false
        editingNotes = false
        cancelTransition()
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
        if step != .permissions && !permissionsReady {
            step = .permissions
            verificationRequested = false
        }
        if step == .ready && !ready {
            step = .connection
            verificationRequested = false
        }
        let target: Step? = if presented && step == .permissions && permissionsReady { .connection }
            else if presented && step == .connection && ready && verificationRequested && !editingNotes { .ready }
            else { nil }
        guard target != transitionTarget else { return }
        cancelTransition()
        guard let target else { return }
        transitionTarget = target
        transition = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(target == .connection ? 650 : 700)) } catch { return }
            guard let self, self.presented, self.transitionTarget == target else { return }
            self.refresh()
            guard self.transitionTarget == target else { return }
            self.continueSetup()
        }
    }

    func notesFocusChanged(_ focused: Bool) {
        editingNotes = focused
        reconcile()
    }

    /// Only an explicit Verify starts automatic completion. A stored key must
    /// leave the notes screen available for review when setup is reopened.
    func verifyConnection() {
        guard step == .connection else { return }
        if settings.verified && settings.maskedKey != nil {
            continueSetup()
        } else {
            verificationRequested = true
            if settings.maskedKey != nil { settings.retryStoredVerification() }
            else { settings.verifyDraft() }
            reconcile()
        }
    }

    private func cancelTransition() {
        transition?.cancel()
        transition = nil
        transitionTarget = nil
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
        switch step {
        case .permissions:
            guard permissionsReady else { return }
            // Even an existing verified key must not skip the notes/review screen.
            cancelTransition()
            step = .connection
        case .connection:
            guard ready else { return }
            settings.flushPendingNotesChanges()
            cancelTransition()
            step = .ready
        case .ready: break
        }
    }

    func back() {
        cancelTransition()
        verificationRequested = false
        step = .permissions
    }

    @discardableResult func finish() -> Bool {
        refresh()
        guard step == .ready, ready else { return false }
        settings.flushPendingNotesChanges()
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
