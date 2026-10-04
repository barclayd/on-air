import AVFoundation
import Foundation

@MainActor
enum OnboardingChecks {
    static func run() async throws {
        let suite = "com.danbarclay.onair.onboarding-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let system = FakeSystem()
        let credentials = Credentials()
        var changes = 0
        let settings = SettingsModel(defaults: defaults, credentials: credentials, verifier: Verifier(), didChange: { changes += 1 })
        let model = OnboardingModel(settings: settings, system: system, defaults: defaults)
        defer { model.disappear() }
        try check(model.shouldPresentOnLaunch, "First launch opens setup")
        model.appear()
        try check(system.requests.isEmpty && system.accessibilityRequests == 0 && system.panes.isEmpty,
                  "Opening setup must not ask for permissions or open System Settings")
        model.continueSetup()
        try check(model.step == .permissions && !model.finish(), "No way to skip unfulfilled requirements and claim completion")

        model.enableMicrophone()
        model.enableMicrophone()
        try check(system.requests.count == 1 && model.requestingMicrophone, "Coalesce repeated permission clicks")
        system.microphoneStatus = .denied
        system.requests[0](true) // Deliberately stale callback: actual macOS state must win.
        try await wait { !model.requestingMicrophone }
        try check(model.microphone == .denied && !model.permissionsReady, "Read live permission rather than trusting callback or click")
        model.enableMicrophone()
        try check(system.panes.last == .microphone && system.requests.count == 1, "Denial routes to Microphone settings; never re-prompts")
        system.microphoneStatus = .restricted
        model.enableMicrophone()
        try check(model.notice?.contains("administrator") == true && system.panes.count == 1, "Restrictions give actionable help without pointless prompts")

        model.enableAccessibility()
        model.enableAccessibility()
        try check(system.accessibilityRequests == 1 && system.panes.last == .accessibility && !model.accessibility,
                  "Accessibility action registers once and opens its pane; it does not simulate a grant")
        system.microphoneStatus = .authorized
        system.accessibilityTrusted = true
        model.refresh()
        try check(model.permissionsReady && !model.ready,
                  "Microphone and Accessibility are the only required permissions; a verified key is still needed")
        model.continueSetup()
        try check(model.step == .connection && !model.finish(), "Require key verification before completion")
        settings.updateKey("sk-fixture-invalid-key")
        settings.verifyDraft()
        try await wait { !settings.verifying }
        model.refresh()
        try check(!model.ready && credentials.key == nil, "Rejected key never completes onboarding")
        settings.updateKey("sk-fixture-valid-key")
        settings.verifyDraft()
        try await wait { !settings.verifying }
        model.refresh()
        try check(model.step == .connection && model.ready && !model.completed,
                  "Verification displays confirmation before automatically advancing")
        let notes = "Use British spelling. Write HubSpot.\nCafé 👩🏽‍💻"
        settings.updateNotes(notes)
        let beforeContinue = changes
        model.continueSetup()
        try check(model.step == .ready && changes == beforeContinue + 1,
                  "Continuing immediately applies saved notes before reporting ready")
        try await Task.sleep(for: .milliseconds(750))
        try check(changes == beforeContinue + 1, "The old debounce must not cause a second connection refresh")

        system.accessibilityTrusted = false
        try check(!model.finish() && model.step == .permissions && !defaults.bool(forKey: OnboardingModel.completionKey),
                  "Recheck at Done so revocation between polls can't record false completion")
        system.accessibilityTrusted = true
        model.continueSetup()
        try check(model.step == .connection, "Restored permissions allow credential checking")
        settings.updateNotes(String(repeating: "x", count: DictationPreferences.notesLimit + 1))
        model.continueSetup()
        try check(model.step == .ready && model.ready,
                  "Invalid optional edits in Settings cannot block essential setup")
        try check(defaults.string(forKey: DictationPreferences.notesKey) == notes, "Invalid notes preserve the previous saved value")
        settings.updateNotes(notes)
        model.continueSetup()
        try check(model.finish() && defaults.bool(forKey: OnboardingModel.completionKey), "Persist successful completion")
        model.disappear()
        // Recreate both models and read through a fresh defaults instance, as at launch.
        let restoredSettings = SettingsModel(defaults: UserDefaults(suiteName: suite)!, credentials: credentials, verifier: Verifier())
        let reopened = OnboardingModel(settings: restoredSettings, system: system, defaults: defaults)
        try check(restoredSettings.notes == notes, "Setup must preserve notes saved in Settings")
        reopened.appear()
        try await wait { !restoredSettings.verifying }
        try check(restoredSettings.verified && restoredSettings.maskedKey == settings.maskedKey,
                  "The stored key is reused, masked, and verified on reopen")
        try await wait { reopened.step == .ready }
        try check(system.panes.allSatisfy { $0 == .microphone || $0 == .accessibility },
                  "Setup only opens essential permission panes")
        restoredSettings.updateNotes("")
        try check(SettingsModel(defaults: defaults, credentials: credentials, verifier: Verifier()).notes.isEmpty,
                  "Clearing optional notes must persist too")
        reopened.disappear()
        try check(reopened.completed && !reopened.shouldPresentOnLaunch,
                  "Completed setup doesn't interrupt subsequent healthy launches")
        credentials.key = nil
        try check(reopened.shouldPresentOnLaunch, "Missing credentials reopen setup on launch")
        credentials.key = "sk-fixture-valid-key"
        system.microphoneStatus = .denied
        reopened.refresh()
        try check(reopened.shouldPresentOnLaunch, "Revoked system permission reopens repair on launch")
        system.opensSuccessfully = false
        reopened.enableMicrophone()
        try check(reopened.notice?.contains("Apple menu") == true, "Failed deep links explain a manual route")
        try check(SetupPane.microphone.url.absoluteString.contains("Privacy_Microphone") &&
                  SetupPane.accessibility.url.absoluteString.contains("Privacy_Accessibility"), "Each switch targets its permission pane")

        // Two native windows share a verifier: closing one must not cancel the other.
        settings.present(owner: "settings")
        settings.present(owner: "onboarding")
        settings.dismiss(owner: "settings")
        try check(settings.verifying, "Closing Settings leaves setup's verification alive")
        try await wait { !settings.verifying }
        try check(settings.verified, "Remaining presentation receives verification result")
        settings.dismiss(owner: "onboarding")
        settings.dismiss(owner: "onboarding") // Native close and SwiftUI disappearance may both arrive.
        try check(settings.keyDraft.isEmpty && !settings.showsKey, "Final close clears sensitive presentation state")
        try await automaticTransitions()
        try await legacyKeyboardPreferenceIsIrrelevant()
        print("PASS: essential-only onboarding, permission/key validation, legacy preference independence, optional Settings isolation, navigation cancellation, and shared window lifecycle")
    }

    private static func automaticTransitions() async throws {
        let suite = "com.danbarclay.onair.auto-setup-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let system = FakeSystem()
        let credentials = Credentials()
        let settings = SettingsModel(defaults: defaults, credentials: credentials, verifier: Verifier())
        let model = OnboardingModel(settings: settings, system: system, defaults: defaults)
        model.appear()
        system.microphoneStatus = .authorized
        model.refresh()
        try await Task.sleep(for: .milliseconds(750))
        try check(model.step == .permissions, "Microphone alone cannot bypass missing Accessibility")
        system.accessibilityTrusted = true
        model.refresh()
        model.disappear()
        try await Task.sleep(for: .milliseconds(750))
        try check(model.step == .permissions, "Closing setup cancels pending automatic navigation")
        model.appear()
        defer { model.disappear() }
        try check(model.step == .connection, "Already-granted permissions need no repeat confirmation")
        settings.updateKey("sk-fixture-valid-key")
        model.verifyConnection()
        try await wait { settings.verified }
        model.refresh()
        system.accessibilityTrusted = false
        model.refresh()
        try await Task.sleep(for: .milliseconds(800))
        try check(model.step == .permissions && !model.ready, "Revocation cancels pending completion")
        system.accessibilityTrusted = true
        model.refresh()
        try await wait { model.step == .connection }
        settings.removeKey()
        model.refresh()
        try await Task.sleep(for: .milliseconds(800))
        try check(model.step == .connection && !model.ready, "Removing a key cancels pending completion")
        settings.updateKey("sk-fixture-valid-key")
        model.verifyConnection()
        try await wait { settings.verified }
        model.refresh()
        model.disappear()
        try await Task.sleep(for: .milliseconds(800))
        try check(model.step == .connection && !model.completed, "Closing during verification confirmation cancels navigation")
        model.appear()
        try await wait { model.step == .ready }
        try check(model.finish(), "An existing verified key advances without an extra confirmation")
    }

    private static func legacyKeyboardPreferenceIsIrrelevant() async throws {
        for previousConfirmation: Bool? in [nil, false, true] {
            let suite = "com.danbarclay.onair.legacy-setup-checks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            if let previousConfirmation {
                defaults.set(previousConfirmation, forKey: "onboarding.globeConfirmed.v1")
            }
            let system = FakeSystem()
            system.microphoneStatus = .authorized
            system.accessibilityTrusted = true
            let credentials = Credentials()
            credentials.key = "sk-fixture-valid-key"
            let settings = SettingsModel(defaults: defaults, credentials: credentials, verifier: Verifier())
            let model = OnboardingModel(settings: settings, system: system, defaults: defaults)
            model.appear()
            defer { model.disappear() }
            try await wait { model.step == .ready }
            try check(model.finish() && !model.shouldPresentOnLaunch,
                      "Absent, false, or true legacy fn confirmation must not gate setup or healthy launches")
            try check(system.requests.isEmpty && system.accessibilityRequests == 0 && system.panes.isEmpty,
                      "Existing permissions and credentials require no additional setup tasks")
        }
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: "Onboarding operation timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private struct Failure: Error { let message: String }
    private final class FakeSystem: SetupSystemAccess {
        var microphoneStatus: AVAuthorizationStatus = .notDetermined
        var accessibilityTrusted = false
        var requests: [@Sendable (Bool) -> Void] = []
        var accessibilityRequests = 0
        var panes: [SetupPane] = []
        var opensSuccessfully = true
        func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) { requests.append(completion) }
        func requestAccessibility() { accessibilityRequests += 1 }
        func open(_ pane: SetupPane) -> Bool { panes.append(pane); return opensSuccessfully }
    }
    private final class Credentials: CredentialStoring {
        var key: String?
        func read() throws -> String? { key }
        func save(_ key: String) throws { self.key = key }
        func remove() throws { key = nil }
    }
    private struct Verifier: APIKeyVerifying {
        func verify(_ key: String) async throws {
            try await Task.sleep(for: .milliseconds(30))
            if key != "sk-fixture-valid-key" { throw TranscriptionError.rejected("invalid_api_key") }
        }
    }
}
