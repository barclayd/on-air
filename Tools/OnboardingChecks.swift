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
        try check(!model.permissionsReady, "fn configuration is also required")
        model.configureKeyboard()
        try check(system.panes.last == .keyboard && !model.globeConfirmed, "Opening Keyboard doesn't count as confirmation")
        model.confirmGlobeSetting(true)
        try check(model.permissionsReady && !model.ready, "Confirmed permissions alone aren't sufficient without a verified key")
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
                  "Verification makes Continue available without hiding the editable notes screen")
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
        try check(model.step == .connection, "A verified stored key never bypasses the notes screen")
        settings.updateNotes(String(repeating: "x", count: DictationPreferences.notesLimit + 1))
        model.continueSetup()
        try check(model.step == .connection && !model.ready && !model.finish(), "Oversized notes cannot silently finish with older values")
        try check(defaults.string(forKey: DictationPreferences.notesKey) == notes, "Invalid notes preserve the previous saved value")
        settings.updateNotes(notes)
        model.continueSetup()
        try check(model.finish() && defaults.bool(forKey: OnboardingModel.completionKey), "Persist successful completion")
        model.disappear()
        // Recreate both models and read through a fresh defaults instance, as at launch.
        let restoredSettings = SettingsModel(defaults: UserDefaults(suiteName: suite)!, credentials: credentials, verifier: Verifier())
        let reopened = OnboardingModel(settings: restoredSettings, system: system, defaults: defaults)
        try check(restoredSettings.notes == notes, "Notes entered in setup must survive recreating Settings")
        reopened.appear()
        try await wait { !restoredSettings.verifying }
        try check(restoredSettings.verified && restoredSettings.maskedKey == settings.maskedKey && reopened.step == .connection,
                  "The stored key is reused, masked, and verified on reopen without skipping the middle screen")
        restoredSettings.updateNotes("")
        try check(SettingsModel(defaults: defaults, credentials: credentials, verifier: Verifier()).notes.isEmpty,
                  "Clearing optional notes must persist too")
        reopened.disappear()
        try check(reopened.completed && reopened.globeConfirmed && !reopened.shouldPresentOnLaunch,
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
                  SetupPane.accessibility.url.absoluteString.contains("Privacy_Accessibility") &&
                  SetupPane.keyboard.url.absoluteString.contains("Keyboard-Settings"), "Each button targets the relevant pane")

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
        print("PASS: onboarding permissions, consent, deep links, revocation, persisted notes/keys, completion, key gating, immediate configuration, and shared window lifecycle")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
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
