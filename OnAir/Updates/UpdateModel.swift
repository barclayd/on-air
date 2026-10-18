import Foundation
import Observation

enum UpdateStatus: Equatable {
    case idle, checking, upToDate, failed
    case available(String)
}

@MainActor
protocol UpdateDriverDelegate: AnyObject {
    func updateDriverChanged()
    func postponeInstallation(_ install: @escaping () -> Void) -> Bool
}

@MainActor
protocol UpdateDriving: AnyObject {
    var delegate: (any UpdateDriverDelegate)? { get set }
    var canCheck: Bool { get }
    var automaticallyChecks: Bool { get set }
    var lastCheck: Date? { get }
    var status: UpdateStatus { get }
    func start() throws
    func check()
}

/// One updater shared by Settings and both menus. Sparkle owns its persisted
/// preferences; this model never changes the app's settings or Keychain items.
@Observable @MainActor
final class UpdateModel: UpdateDriverDelegate {
    private(set) var status: UpdateStatus = .idle
    private(set) var automaticallyChecks = false
    private(set) var lastCheck: Date?
    private(set) var waitingToInstall = false
    private var driverCanCheck = false
    @ObservationIgnored private let driver: any UpdateDriving
    @ObservationIgnored private let dictationIsBusy: () -> Bool
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var started = false

    init(driver: any UpdateDriving, dictationIsBusy: @escaping () -> Bool) {
        self.driver = driver
        self.dictationIsBusy = dictationIsBusy
        driver.delegate = self
    }

    var canCheck: Bool { driverCanCheck && !dictationIsBusy() && !waitingToInstall }
    var buttonTitle: String {
        if case .available = status { return "Update Available…" }
        return "Check for Updates…"
    }
    var statusText: String? {
        if waitingToInstall { return "The update will install when your dictation is finished." }
        switch status {
        case .idle: return nil
        case .checking: return "Checking for updates…"
        case .upToDate: return "On Air is up to date."
        case .available(let version): return "On Air \(version) is available."
        case .failed: return "Unable to check for updates. Please try again."
        }
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            try driver.start()
            updateDriverChanged()
        } catch {
            status = .failed
            driverCanCheck = false
        }
        observeDictation()
    }

    func check() {
        guard canCheck else { return }
        driver.check()
        updateDriverChanged()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        driver.automaticallyChecks = enabled
        updateDriverChanged()
    }

    func updateDriverChanged() {
        status = driver.status
        driverCanCheck = driver.canCheck
        automaticallyChecks = driver.automaticallyChecks
        lastCheck = driver.lastCheck
    }

    func postponeInstallation(_ install: @escaping () -> Void) -> Bool {
        guard dictationIsBusy() else { return false }
        pendingInstall = install
        waitingToInstall = true
        return true
    }

    private func observeDictation() {
        withObservationTracking {
            _ = dictationIsBusy()
        } onChange: { [weak self] in
            Task { @MainActor in self?.dictationChanged() }
        }
    }

    private func dictationChanged() {
        // Read the current state after the observation notification (which is
        // delivered before the value changes). Resume once, without an await
        // between verifying that dictation is finished and invoking Sparkle.
        if !dictationIsBusy(), let install = pendingInstall {
            pendingInstall = nil
            waitingToInstall = false
            install()
        }
        observeDictation()
    }
}
