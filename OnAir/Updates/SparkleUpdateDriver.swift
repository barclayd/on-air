import Foundation
import Sparkle

@MainActor
// Sparkle's user-driver delegate runs on the main thread but its Objective-C
// protocol has not adopted NS_SWIFT_UI_ACTOR yet.
final class SparkleUpdateDriver: NSObject, UpdateDriving, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    weak var delegate: (any UpdateDriverDelegate)?
    private(set) var status: UpdateStatus = .idle
    private var observations: [NSKeyValueObservation] = []
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    var canCheck: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func start() throws {
        let updater = controller.updater
        // KVO callbacks run on Sparkle's main thread. Hop back through the main
        // actor so Swift 6 can also verify the lifetime of the observation.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.delegate?.updateDriverChanged() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.delegate?.updateDriverChanged() }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.delegate?.updateDriverChanged() }
            }
        ]
        try updater.start()
    }

    func check() {
        if case .available = status {
            // Bring the existing gentle reminder into focus; do not create a
            // second updater or a duplicate download session.
        } else {
            status = .checking
        }
        controller.checkForUpdates(nil)
    }

    // Background checks must never activate On Air or take the dictation field
    // away. A menu label and Settings status provide the gentle reminder.
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        status = .available(update.displayVersionString)
        delegate?.updateDriverChanged()
    }

    func standardUserDriverWillFinishUpdateSession() {
        if case .available = status { status = .idle }
        delegate?.updateDriverChanged()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(item.displayVersionString)
        delegate?.updateDriverChanged()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = .upToDate
        delegate?.updateDriverChanged()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        if !(error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue) {
            status = .failed
            delegate?.updateDriverChanged()
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError?,
           !(error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue) {
            status = .failed
        } else if status == .checking {
            status = .idle
        }
        delegate?.updateDriverChanged()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        delegate?.postponeInstallation(installHandler) ?? false
    }
}
