import Foundation

@MainActor
enum SettingsChecks {
    static func run() async throws {
        let suite = "com.danbarclay.onair.settings-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryCredentials()
        let verifier = ControlledVerifier()
        var changes = 0
        let model = SettingsModel(defaults: defaults, credentials: store, verifier: verifier, didChange: { changes += 1 })
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(message: message) }
        }
        try check(model.glow.intensity == 0.5, "Existing users keep the original glow")
        model.glow.updateIntensity(0.83, at: 100)
        try check(model.glow.intensity == 0.8, "Glow has eleven evenly selectable levels")
        try check(defaults.double(forKey: GlowPreferences.intensityKey) == 0.8, "Glow saves immediately")
        try check(GlowPreferences(defaults: defaults).intensity == 0.8, "Glow survives a new model/app launch")
        try check(model.glow.displayedIntensity(at: 100) == 0.5, "Changes start at the current appearance without a jump")
        let midway = model.glow.displayedIntensity(at: 100.12)
        try check(midway > 0.5 && midway < 0.8, "Appearance interpolates while recording")
        model.glow.updateIntensity(0.1, at: 100.12)
        try check(model.glow.displayedIntensity(at: 100.12) == midway, "Reversing the slider preserves continuity")
        try check(model.glow.displayedIntensity(at: 100.12, reducedMotion: true) == 0.1, "Reduce Motion skips interpolation")
        try check(abs(model.glow.displayedIntensity(at: 101) - 0.1) < 0.0001, "Appearance settles at the selection")
        try check(changes == 0 && verifier.calls == 0, "Glow must never reconfigure or verify transcription")
        for (saved, expected) in [(-1.0, 0.0), (2.0, 1.0), (0.76, 0.8), (Double.nan, 0.5), (Double.infinity, 0.5)] {
            defaults.set(saved, forKey: GlowPreferences.intensityKey)
            try check(GlowPreferences(defaults: defaults).intensity == expected, "Invalid or old preferences normalize safely")
        }
        defaults.set("invalid", forKey: GlowPreferences.intensityKey)
        try check(GlowPreferences(defaults: defaults).intensity == 0.5, "Non-numeric preferences use the default")
        model.appear()
        try check(model.maskedKey == nil && !model.verifying && verifier.calls == 0, "Empty settings must not verify a nonexistent key")
        let notesModel = SettingsModel(defaults: defaults, credentials: store, verifier: verifier)
        let notes = "Use British spelling. Write HubSpot. Café 👩🏽‍💻\nKeep API uppercase."
        notesModel.updateNotes(notes)
        try check(defaults.string(forKey: DictationPreferences.notesKey) == notes, "Notes must persist before the debounce")
        let reopened = SettingsModel(defaults: defaults, credentials: store, verifier: verifier)
        try check(reopened.notes == notes, "Notes survive recreating Settings")
        try check(DictationPreferences.prompt(notes: notes).hasSuffix(notes), "Prompt retains notes without reformatting")
        try check(DictationPreferences.prompt(notes: " \n ") == DictationPreferences.basePrompt, "Empty notes preserve the existing prompt")
        notesModel.updateNotes(String(repeating: "x", count: DictationPreferences.notesLimit + 1))
        try check(notesModel.notesError != nil && defaults.string(forKey: DictationPreferences.notesKey) == notes,
                  "Oversized notes must not overwrite the last usable notes")
        notesModel.updateNotes("")
        try check(defaults.string(forKey: DictationPreferences.notesKey) == "" && notesModel.notesError == nil, "Clearing notes persists")

        model.updateKey("not a key")
        model.verifyDraft()
        try check(verifier.calls == 0 && model.keyError != nil && store.key == nil, "Malformed keys never leave the app")
        model.updateKey("  sk-fixture-first-key\n")
        model.showsKey = true
        model.verifyDraft()
        try await verifier.waitForCalls(1)
        try check(model.verifying && store.key == nil, "Never save a key before OpenAI accepts it")
        // SecureField can publish the same value again when Verify ends editing.
        // This commit must not cancel the in-flight verification; a real edit must.
        model.updateKey("  sk-fixture-first-key\n")
        try check(model.verifying && verifier.calls == 1,
                  "Committing an unchanged key must not cancel verification or require a second click")
        verifier.complete(0, with: .success(()))
        try await wait { !model.verifying }
        try check(store.key == "sk-fixture-first-key" && model.verified, "Save the trimmed verified credential")
        try check(model.keyDraft.isEmpty && !model.showsKey && model.maskedKey == "sk-••••••••••••••-key",
                  "After verification retain only a masked key in the view model")
        try check(changes == 1, "Credential save reconnects once")

        store.failRemove = true
        model.removeKey()
        try check(model.maskedKey != nil && store.key != nil && model.keyError != nil, "Failed removal must keep the stored-key state")
        store.failRemove = false
        model.removeKey()
        try check(store.key == nil && model.maskedKey == nil && !model.verified && model.keyError == nil,
                  "Successful removal clears the UI and stored credential")

        model.updateKey("sk-fixture-stale-key")
        model.verifyDraft()
        try await verifier.waitForCalls(2)
        model.updateKey("sk-fixture-current-key")
        model.verifyDraft()
        try await verifier.waitForCalls(3)
        // The transport deliberately ignores cancellation to reproduce late replies.
        verifier.complete(1, with: .success(()))
        await Task.yield()
        try check(store.key == nil && model.verifying, "An older response must not save a replaced key or clear a newer request")
        verifier.complete(2, with: .failure(TranscriptionError.rejected("invalid_api_key")))
        try await wait { !model.verifying }
        try check(store.key == nil && !model.verified && model.keyError?.contains("didn’t accept") == true,
                  "Rejected credentials remain editable and are never stored")

        model.updateKey("sk-fixture-closing-key")
        model.verifyDraft()
        try await verifier.waitForCalls(4)
        model.disappear()
        verifier.complete(3, with: .success(()))
        await Task.yield()
        try check(store.key == nil && model.keyDraft.isEmpty && !model.showsKey && !model.verifying,
                  "Closing Settings cancels verification and clears the unsaved credential")

        model.updateKey("sk-fixture-keychain-failure")
        store.failSave = true
        model.verifyDraft()
        try await verifier.waitForCalls(5)
        verifier.complete(4, with: .success(()))
        try await wait { !model.verifying }
        try check(!model.verified && model.maskedKey == nil && !model.keyDraft.isEmpty && model.keyError?.contains("Keychain") == true,
                  "Keychain failure must not claim success or discard the draft")

        store.key = "sk-fixture-existing-key"
        model.appear()
        try await verifier.waitForCalls(6)
        try check(model.maskedKey != nil && !model.verified, "A stored key must not be labelled Verified before checking")
        model.removeKey()
        verifier.complete(5, with: .success(()))
        await Task.yield()
        try check(store.key == nil && model.maskedKey == nil && !model.verified, "A late verification cannot resurrect a removed key")
        model.disappear()
        print("PASS: settings persistence, prompt context, validation, masked credentials, failure recovery, and cancellation races (no Keychain or network access)")
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: "Settings operation timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private struct Failure: Error { let message: String }

    private final class MemoryCredentials: CredentialStoring {
        var key: String?
        var failSave = false
        var failRemove = false
        func read() throws -> String? { key }
        func save(_ key: String) throws { if failSave { throw CredentialStoreError.unavailable }; self.key = key }
        func remove() throws { if failRemove { throw CredentialStoreError.unavailable }; key = nil }
    }

    private final class ControlledVerifier: APIKeyVerifying {
        private(set) var calls = 0
        private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
        func verify(_ key: String) async throws {
            let index = calls
            calls += 1
            try await withCheckedThrowingContinuation { pending[index] = $0 }
        }
        func complete(_ index: Int, with result: Result<Void, Error>) { pending.removeValue(forKey: index)!.resume(with: result) }
        func waitForCalls(_ count: Int) async throws {
            try await SettingsChecks.wait { calls >= count }
        }
    }
}
