import Foundation
import Observation

@MainActor
protocol APIKeyVerifying {
    func verify(_ key: String) async throws
}

struct OpenAIKeyVerifier: APIKeyVerifying {
    func verify(_ key: String) async throws {
        let client = OpenAITranscriber(key: { key }, notes: { "" })
        defer { client.shutdown() }
        // Authenticate and configure the real transcription model. No microphone,
        // audio append, or transcript request is involved in this check.
        try await client.verifyConnection()
    }
}

@MainActor
@Observable
final class SettingsModel {
    private(set) var notes: String
    private(set) var notesSaved = false
    private(set) var notesError: String?
    private(set) var keyDraft = ""
    var showsKey = false
    private(set) var maskedKey: String?
    private(set) var verifying = false
    private(set) var verified = false
    private(set) var keyError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let verifier: any APIKeyVerifying
    @ObservationIgnored private let didChange: () -> Void
    @ObservationIgnored private var saveFeedback: Task<Void, Never>?
    @ObservationIgnored private var verification: Task<Void, Never>?
    @ObservationIgnored private var verificationID = UUID()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var presentationOwners: Set<String> = []
    @ObservationIgnored private var notesChangePending = false

    init(defaults: UserDefaults = .standard,
         credentials: any CredentialStoring = KeychainCredentials(),
         verifier: any APIKeyVerifying = OpenAIKeyVerifier(),
         didChange: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.credentials = credentials
        self.verifier = verifier
        self.didChange = didChange
        notes = defaults.string(forKey: DictationPreferences.notesKey) ?? ""
    }

    var canVerify: Bool { !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !verifying }

    var hasSavedKey: Bool { (try? credentials.read()) != nil }

    func present(owner: String) {
        presentationOwners.insert(owner)
        appear()
    }

    func dismiss(owner: String) {
        guard presentationOwners.remove(owner) != nil else { return }
        if presentationOwners.isEmpty { disappear() }
    }

    func appear() {
        guard !loaded else { return }
        loaded = true
        maskedKey = nil
        verified = false
        keyError = nil
        do {
            if let key = try credentials.read() {
                maskedKey = Self.mask(key)
                verify(key, save: false)
            }
        } catch { keyError = "Keychain is unavailable. Unlock your Mac and try again."; loaded = false }
    }

    func updateNotes(_ value: String) {
        notes = value
        notesSaved = false
        saveFeedback?.cancel()
        guard value.count <= DictationPreferences.notesLimit else {
            notesError = "Keep notes under \(DictationPreferences.notesLimit.formatted()) characters. Your previous notes are still in use."
            return
        }
        notesError = nil
        // Persist immediately; the debounce is only for feedback and reconnecting.
        defaults.set(value, forKey: DictationPreferences.notesKey)
        notesChangePending = true
        saveFeedback = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self else { return }
            self.flushPendingNotesChanges()
            self.notesSaved = true
            do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
            self.notesSaved = false
        }
    }

    /// Start warming the connection with saved notes before setup reports ready.
    /// The normal debounce can still show feedback, but must not reconnect twice.
    func flushPendingNotesChanges() {
        guard notesChangePending else { return }
        notesChangePending = false
        didChange()
    }

    func updateKey(_ value: String) {
        cancelVerification()
        keyDraft = value
        keyError = nil
    }

    func verifyDraft() {
        guard canVerify else { return }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 10, !key.contains(where: \.isWhitespace) else {
            keyError = "Enter a complete OpenAI API key beginning with sk-."
            return
        }
        verify(key, save: true)
    }

    func retryStoredVerification() {
        loaded = false
        appear()
    }

    private func verify(_ key: String, save: Bool) {
        cancelVerification()
        let id = verificationID
        verifying = true
        keyError = nil
        verification = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.verifier.verify(key)
                guard !Task.isCancelled, self.verificationID == id else { return }
                if save { try self.credentials.save(key) }
                self.maskedKey = Self.mask(key)
                self.keyDraft = ""
                self.showsKey = false
                self.verified = true
                if save {
                    // The credential refresh also picks up all notes already saved.
                    self.notesChangePending = false
                    self.didChange()
                }
            } catch {
                guard !Task.isCancelled, self.verificationID == id else { return }
                self.keyError = Self.message(for: error)
                self.verified = false
            }
            guard self.verificationID == id else { return }
            self.verifying = false
        }
    }

    func removeKey() {
        cancelVerification()
        do {
            try credentials.remove()
            maskedKey = nil
            keyDraft = ""
            showsKey = false
            verified = false
            keyError = nil
            didChange()
        } catch { keyError = "Couldn’t remove the key from Keychain. Please try again." }
    }

    func disappear() {
        // Don't retain a revealed or unsaved credential after the window closes.
        cancelVerification()
        keyDraft = ""
        showsKey = false
        loaded = false
    }

    private func cancelVerification() {
        verificationID = UUID()
        verification?.cancel()
        verification = nil
        verifying = false
    }

    private static func mask(_ key: String) -> String { "sk-" + String(repeating: "•", count: 14) + key.suffix(4) }

    private static func message(for error: Error) -> String {
        if error is CredentialStoreError { return "OpenAI accepted the key, but Keychain couldn’t save it. Please try again." }
        switch error as? TranscriptionError {
        case .rejected(let code) where ["invalid_api_key", "401"].contains(code):
            return "OpenAI didn’t accept this key. Check it and try again."
        case .rejected(let code) where ["insufficient_quota", "rate_limit_exceeded", "429"].contains(code):
            return "OpenAI’s usage limit was reached. Check your billing or try again shortly."
        case .rejected: return "This key couldn’t access transcription. Check its OpenAI permissions."
        default: return "Couldn’t reach OpenAI. Check your connection and try again."
        }
    }
}
