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

        let large = NSPasteboardItem()
        let largeData = Data(repeating: 0x5a, count: 32 * 1024 * 1024 + 1)
        let binaryType = NSPasteboard.PasteboardType("com.onair.large-fixture")
        large.setData(largeData, forType: binaryType)
        board.clearContents(); board.writeObjects([large])
        let largeCount = board.changeCount
        try check(ClipboardSnapshot.capture(board) == nil, "Large clip must use a clipboard-free fallback")
        try check(board.changeCount == largeCount, "Failed snapshot must not mutate clipboard")
        try check(board.data(forType: binaryType) == largeData, "Large clipboard data must remain intact")

        guard let source = CGEventSource(stateID: .privateState) else { throw CheckFailure(message: "Create test event source") }
        let sample = "Version 1.2.3 — café 👩🏽‍💻 and e\u{301} stay intact. " + String(repeating: "Long dictation. ", count: 40)
        guard let events = UnicodeInsertion.events(for: sample, source: source) else { throw CheckFailure(message: "Create Unicode events") }
        var restoredText = ""
        try check(events.count > 2 && events.count % 2 == 0, "Long text uses complete down/up event pairs")
        for index in stride(from: 0, to: events.count, by: 2) {
            for (event, type) in [(events[index], CGEventType.keyDown), (events[index + 1], CGEventType.keyUp)] {
                try check(event.type == type && event.flags.isEmpty, "Balanced Unicode events with no shortcut modifiers")
                try check(event.getIntegerValueField(.keyboardEventKeycode) == 0, "Never send Return or Tab")
            }
            var count = 0
            var units = [UniChar](repeating: 0, count: 20)
            events[index].keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
            try check(count > 0 && count <= 20, "Bounded event payload")
            restoredText += String(decoding: units.prefix(count), as: UTF16.self)
        }
        try check(restoredText == sample, "Unicode event stream preserves long text, emoji, and combining characters")
        for unsafe in ["", "Send\nmessage", "Send\rmessage", "Next\tfield", "Cancel\u{1b}", "Para\u{2029}graph", "a" + String(repeating: "\u{301}", count: 21)] {
            try check(UnicodeInsertion.events(for: unsafe, source: source) == nil, "Unsafe or oversized grapheme must fall back to Copy")
        }
        try check(board.changeCount == largeCount, "Building direct insertion must leave clipboard unchanged")

        let missingProvider = UnavailableClipboardProvider()
        let promised = NSPasteboardItem()
        promised.setString("Keep this readable representation", forType: .string)
        let unavailableType = NSPasteboard.PasteboardType("com.onair.unavailable-fixture")
        promised.setDataProvider(missingProvider, forTypes: [unavailableType])
        board.clearContents(); board.writeObjects([promised])
        let promisedCount = board.changeCount
        try check(ClipboardSnapshot.capture(board) == nil, "Unreadable promised representation must use a clipboard-free fallback")
        try check(board.changeCount == promisedCount, "Unreadable promise must not mutate clipboard")
        try check(board.string(forType: .string) == "Keep this readable representation", "Keep readable data when another representation is unavailable")
        print("PASS: oversized/unreadable clipboard preservation and Unicode insertion framing/control-character rejection (events never posted)")
    }
    struct CheckFailure: Error { let message: String }
}

private final class UnavailableClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // Reproduce an advertised representation whose owner cannot provide data.
    }
}
