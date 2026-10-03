import Foundation

/// Local preferences contain dictation hints only. Credentials belong in Keychain.
enum DictationPreferences {
    static let notesKey = "dictationNotes"
    // Keep hints concise and leave ample room for the built-in transcription context.
    static let notesLimit = 1_000
    static let basePrompt = """
    English dictation. Use British English spelling.
    Write spoken version numbers as digits separated by periods, for example version 1.2.3.
    """

    static func prompt(notes: String) -> String {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? basePrompt : basePrompt + "\n\nDictation notes:\n" + notes
    }
}
