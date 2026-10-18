import Foundation
import Observation

@MainActor enum UpdateChecks {
    static func run() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw CoreChecks.CheckFailure(message: message) }
        }
        let suite = "com.onair.update-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Keep my vocabulary", forKey: "dictationNotes")
        defaults.set(0.3, forKey: "recordingGlowIntensity")
        defaults.set(true, forKey: "onboarding.completed.v1")
        let busy = UpdateBusyFixture()
        let driver = UpdateCheckDriver(defaults: defaults)
        let model = UpdateModel(driver: driver, dictationIsBusy: { busy.recording || busy.transcribing || busy.pending || busy.retry })
        model.start(); model.start()
        try check(driver.starts == 1 && model.canCheck, "Only one updater is started")
        try check(model.automaticallyChecks, "Automatic checking default is reflected")
        model.setAutomaticallyChecks(false)
        let relaunched = UpdateModel(driver: UpdateCheckDriver(defaults: defaults), dictationIsBusy: { false })
        relaunched.start()
        try check(!relaunched.automaticallyChecks, "Automatic check choice persists across launches")
        try check(defaults.string(forKey: "dictationNotes") == "Keep my vocabulary" && defaults.double(forKey: "recordingGlowIntensity") == 0.3 && defaults.bool(forKey: "onboarding.completed.v1"), "Updater preserves existing app preferences")

        busy.recording = true
        model.check()
        try check(driver.checks == 0 && !model.canCheck, "Manual check cannot steal focus during recording")
        busy.recording = false
        model.check(); model.check()
        try check(driver.checks == 1 && model.status == .checking && !model.canCheck, "Repeated checks cannot create duplicate sessions")
        driver.finish(.upToDate)
        try check(model.canCheck && model.status == .upToDate && model.lastCheck != nil, "No-update result recovers the check action")
        driver.finish(.failed)
        try check(model.canCheck && model.status == .failed, "Network or validation failure remains retryable")
        driver.finish(.available("1.0.8"))
        try check(model.buttonTitle == "Update Available…" && model.statusText?.contains("1.0.8") == true, "Quiet update discovery surfaces a menu and Settings reminder")
        model.check()
        try check(driver.checks == 2, "A reminder uses the same updater action")
        driver.finish(.idle)
        try check(model.buttonTitle == "Check for Updates…", "Dismissed or skipped update clears the reminder")

        var installs = 0
        try check(!model.postponeInstallation { installs += 1 }, "An idle app need not defer installation")
        try check(installs == 0, "Sparkle owns the immediate installation callback")
        busy.recording = true
        try check(model.postponeInstallation { installs += 1 }, "Recordings defer relaunch")
        try check(model.waitingToInstall && !model.canCheck, "Only one update can await dictation")
        busy.transcribing = true; busy.recording = false
        await settle()
        try check(installs == 0, "Finishing audio is still protected")
        busy.pending = true; busy.transcribing = false
        await settle()
        try check(installs == 0, "Copy recovery must not be lost on restart")
        busy.retry = true; busy.pending = false
        await settle()
        try check(installs == 0, "Retry audio must not be lost on restart")
        busy.retry = false
        await settle()
        try check(installs == 1 && !model.waitingToInstall, "Relaunch resumes once when all dictation work is resolved")
        busy.recording = true; await settle(); busy.recording = false; await settle()
        try check(installs == 1, "Later holds do not invoke a stale installation callback")

        let broken = UpdateCheckDriver(defaults: defaults)
        broken.failsToStart = true
        let failed = UpdateModel(driver: broken, dictationIsBusy: { false })
        failed.start(); failed.check()
        try check(failed.status == .failed && !failed.canCheck && broken.checks == 0, "Misconfigured updater fails without starting a check")
        print("PASS: updater persistence, shared checks, quiet reminders, failures, and recording/transcription/recovery-safe relaunch")
    }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(10)) }
}

@Observable @MainActor private final class UpdateBusyFixture {
    var recording = false
    var transcribing = false
    var pending = false
    var retry = false
}

@MainActor private final class UpdateCheckDriver: UpdateDriving {
    weak var delegate: (any UpdateDriverDelegate)?
    var canCheck = false
    var status: UpdateStatus = .idle
    var lastCheck: Date?
    var starts = 0, checks = 0
    var failsToStart = false
    let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults; defaults.register(defaults: ["SUEnableAutomaticChecks": true]) }
    var automaticallyChecks: Bool {
        get { defaults.bool(forKey: "SUEnableAutomaticChecks") }
        set { defaults.set(newValue, forKey: "SUEnableAutomaticChecks") }
    }
    func start() throws {
        starts += 1
        if failsToStart { throw CocoaError(.fileReadUnknown) }
        canCheck = true
    }
    func check() { checks += 1; canCheck = false; status = .checking }
    func finish(_ status: UpdateStatus) {
        self.status = status; canCheck = true; lastCheck = Date()
        delegate?.updateDriverChanged()
    }
}
