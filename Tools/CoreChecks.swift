import AppKit
import Foundation

@main
struct CoreChecks {
    @MainActor static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw CheckFailure(message: message) }
        }
        let fake = "sk-fixture-not-a-real-credential"
        for assignment in ["OPENAI_API_KEY=\(fake)", "export OPENAI_API_KEY = '\(fake)' # comment", "OPENAI_API_KEY=\"\(fake)\""] {
            try check(APIKeyStore.parse(assignment) == fake, "Literal dotenv parsing")
        }
        try check(APIKeyStore.parse("UNRELATED=\(fake)") == nil, "Do not read unrelated secrets")
        try check(APIKeyStore.parse("OPENAI_API_KEY=$(echo invalid)") == nil, "Never execute shell substitutions")
        try check(APIKeyStore.parse("OPENAI_API_KEY='unclosed") == nil, "Reject malformed quoting")
        print("PASS: literal key parsing, malformed values, no shell execution")

        let pcm = Data([0x34, 0x12, 0xff, 0x7f, 0x00, 0x80, 0x00, 0x00])
        let wav = FileTranscription.wav(pcm)
        try check(wav.count == pcm.count + 44, "WAV header length")
        try check(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF", "WAV signature")
        try check(wav.suffix(pcm.count) == pcm, "WAV must not truncate or alter the PCM")
        let rate = wav.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self)) }
        try check(rate == 24_000, "WAV sample rate")
        try check(MicrophoneMeter.level(pcm: Data(repeating: 0, count: 480)) == 0, "Silence has no energy")
        try check(MicrophoneMeter.level(pcm: pcm) > 0.9, "Signed little-endian PCM drives the meter")
        print("PASS: PCM energy and lossless PCM16 WAV framing")

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("Original text", forType: .string)
        let rich = Data("{\\rtf1 Original text}".utf8)
        first.setData(rich, forType: .rtf)
        let second = NSPasteboardItem()
        let blob = Data([0, 1, 2, 255])
        second.setData(blob, forType: NSPasteboard.PasteboardType("com.onair.fixture"))
        board.writeObjects([first, second])
        guard let snapshot = ClipboardSnapshot.capture(board) else { throw CheckFailure(message: "Capture multi-item clipboard") }
        board.clearContents(); board.setString("Transcript", forType: .string)
        let ours = board.changeCount
        try check(snapshot.restore(board, ifUnchanged: ours), "Restore our paste's clipboard transaction")
        try check(board.pasteboardItems?.count == 2, "Preserve multiple clipboard items")
        try check(board.pasteboardItems?.first?.data(forType: .rtf) == rich, "Preserve rich text representations")
        try check(board.pasteboardItems?.last?.data(forType: NSPasteboard.PasteboardType("com.onair.fixture")) == blob, "Preserve arbitrary binary data")
        board.clearContents(); board.setString("New user copy", forType: .string)
        try check(!snapshot.restore(board, ifUnchanged: ours), "Do not restore over newer user data")
        try check(board.string(forType: .string) == "New user copy", "The newer user clipboard must survive")
        print("PASS: clipboard formats, multiple items, and concurrent user-copy protection")
    }
    struct CheckFailure: Error { let message: String }
}
