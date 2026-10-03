import Foundation

/// Explicit live-API smoke test. Only accepts a generated benchmark WAV path.
/// Never starts a microphone or writes credentials to Keychain.
@main
struct TranscriptionSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw TranscriptionError.noAudio }
        let wav = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var offset = 12
        var pcm = Data()
        while offset + 8 <= wav.count {
            let count = wav.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))) }
            if String(decoding: wav[offset..<offset+4], as: UTF8.self) == "data" {
                pcm = wav.subdata(in: offset+8..<min(offset+8+count, wav.count)); break
            }
            offset += 8 + count + count % 2
        }
        guard !pcm.isEmpty else { throw TranscriptionError.noAudio }
        let contents = try String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env"), encoding: .utf8)
        guard let key = APIKeyStore.parse(contents) else { throw TranscriptionError.credentials }
        let transcriber = OpenAITranscriber(key: { key })
        transcriber.warm()
        for iteration in 1...2 {
            transcriber.begin()
            for offset in stride(from: 0, to: pcm.count, by: 4_800) {
                transcriber.append(pcm.subdata(in: offset..<min(offset + 4_800, pcm.count)))
                try await Task.sleep(for: .milliseconds(100))
            }
            let start = ProcessInfo.processInfo.systemUptime
            let text = try await transcriber.finish()
            guard text.lowercased().contains("team"), text.lowercased().contains("lunch") else {
                throw TranscriptionError.invalidResponse
            }
            print("Turn \(iteration): complete transcript verified; release-to-final \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))s")
        }
        transcriber.shutdown()
    }
}
