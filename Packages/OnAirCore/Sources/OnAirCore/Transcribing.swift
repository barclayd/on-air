import Foundation

@MainActor
public protocol Transcribing: AnyObject {
    func warm()
    func begin()
    func append(_ pcm: Data)
    func finish() async throws -> String
    func retry(_ pcm: Data) async throws -> String
    func cancel()
    func shutdown()
}

public enum TranscriptionError: Error, LocalizedError {
    case credentials, connection, timeout, rejected(String), noAudio, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .credentials: "Add your OpenAI key in Settings"
        case .connection: "Connection lost — retry transcription"
        case .timeout: "Transcription timed out — retry transcription"
        case .rejected(let code):
            switch code {
            case "invalid_api_key", "401": "OpenAI key was rejected"
            case "insufficient_quota", "rate_limit_exceeded", "429": "OpenAI limit reached — retry shortly"
            default: "OpenAI could not transcribe — retry transcription"
            }
        case .noAudio:
            #if os(iOS)
            "No speech captured — tap the microphone to try again"
            #else
            "No speech captured — hold fn and try again"
            #endif
        case .invalidResponse: "Incomplete transcription — retry transcription"
        }
    }
}
