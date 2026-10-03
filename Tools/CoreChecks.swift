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

        let versions = [
            ("one dot two dot six", "1.2.6"),
            ("One DOT Two DoT Six.", "1.2.6."),
            ("Use (one dot two dot six), please.", "Use (1.2.6), please."),
            ("Use 1 dot two dot 6.", "Use 1.2.6."),
            ("Use 1.2 dot six.", "Use 1.2.6."),
            ("one dot 2.6", "1.2.6"),
            ("Version zero dot ten dot two", "Version 0.10.2"),
            ("two dot twenty-one dot one hundred and six", "2.21.106"),
            ("one dot two dot nine hundred ninety nine", "1.2.999"),
            ("one dot two dot one hundred", "1.2.100"),
            ("one dot two dot one hundred and check it", "1.2.100 and check it"),
            ("one dot two dot zero zero six", "1.2.006"),
            ("01 dot 002 dot 12345678901234567890", "01.002.12345678901234567890"),
            ("zero dot oh dot seven dot four", "0.0.7.4"),
            ("one\tdot\ttwo\tdot\tsix", "1.2.6"),
            ("one\u{a0}dot\u{a0}two\u{a0}dot\u{a0}six", "1.2.6"),
            ("👩🏽‍💻 Use one dot two dot six and one dot three dot zero. Café!", "👩🏽‍💻 Use 1.2.6 and 1.3.0. Café!"),
            ("one dot two dot six\nzero dot ten dot two", "1.2.6\n0.10.2"),
        ]
        let unchanged = [
            "", "Use version 1.2.6.", "One. Two. Six.", "one point two point six",
            "one dot two", "version one dot two", "one dot two dot sixteenth",
            "someone dot two dot six", "one dot two dot six hundred thousand",
            "one thousand dot two dot three", "one dot two dot six million",
            "one dot two dot sixty twenty", "twenty thirteen dot one dot two",
            "one hundred zero dot two dot three", "one dot two. Six people arrived.",
            "one dot two dot\nsix", "one dot two.\nSix people arrived.",
            "https://one dot two dot six", "team@one dot two dot six",
            "one dot two dot six@example.com", "build_one dot two dot six",
            "one dot two dot six dot beta", "alpha dot one dot two dot six",
            "one dot two dot six.com", "minus one dot two dot six",
            "negative one dot two dot six", "one dot two dot six-beta",
            "one dot two dot six-eight", "one dot two dot twenty--one",
            "one dot two dot twenty - one",
            "éone dot two dot six", "one dot two dot sixé",
            "one day, two meetings, six people. Join the dots.",
        ]
        for (input, expected) in versions + unchanged.map({ ($0, $0) }) {
            let actual = VersionNumberFormatter.format(input)
            try check(actual == expected, "Version formatting: \(String(reflecting: input)) → \(String(reflecting: actual)); expected \(String(reflecting: expected))")
            try check(VersionNumberFormatter.format(actual) == actual, "Version formatting must be idempotent")
        }
        print("PASS: \(versions.count + unchanged.count) version-formatting cases, preserved surrounding text, and idempotence")

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
