import Foundation

@MainActor
protocol Transcribing: AnyObject {
    func warm()
    func begin()
    func append(_ pcm: Data)
    func finish() async throws -> String
    func retry(_ pcm: Data) async throws -> String
    func cancel()
    func shutdown()
}

enum TranscriptionError: Error, LocalizedError {
    case credentials, connection, timeout, rejected(String), noAudio, invalidResponse

    var errorDescription: String? {
        switch self {
        case .credentials: "OpenAI key unavailable — check ~/.env or Keychain"
        case .connection: "Connection lost — retry transcription"
        case .timeout: "Transcription timed out — retry transcription"
        case .rejected(let code):
            switch code {
            case "invalid_api_key", "401": "OpenAI key was rejected"
            case "insufficient_quota", "rate_limit_exceeded", "429": "OpenAI limit reached — retry shortly"
            default: "OpenAI could not transcribe — retry transcription"
            }
        case .noAudio: "No speech captured — hold fn and try again"
        case .invalidResponse: "Incomplete transcription — retry transcription"
        }
    }
}
