import Foundation

/// Fixture expectations describe user-visible edits, independently of the parser.
enum VersionFormattingChecks {
    static func run() throws {
        var failures: [String] = []
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
        // Keep punctuation, spelling, whitespace, and independent numeric facts intact.
        let sentences = [
            ("Please ship one dot two dot six by 12:30; it costs £2.60.", "Please ship 1.2.6 by 12:30; it costs £2.60."),
            ("Use one dot two dot six, not one dot two dot seven!", "Use 1.2.6, not 1.2.7!"),
            ("Roll back from 1.2.6 to one dot two dot five.", "Roll back from 1.2.6 to 1.2.5."),
            ("Compare one dot two dot six with two dot zero dot one.\nKeep the café’s wording.", "Compare 1.2.6 with 2.0.1.\nKeep the café’s wording."),
            ("We said ‘one dot two dot six’; keep the quotes.", "We said ‘1.2.6’; keep the quotes."),
            ("  Release\tone dot two dot six…  \r\n", "  Release\t1.2.6…  \r\n"),
            ("one dot two dot three hundred and check one dot two dot four", "1.2.300 and check 1.2.4"),
            ("one dot two dot six — then one dot three dot zero", "1.2.6 — then 1.3.0"),
            ("one dot two dot six; minus one dot two dot six; one dot two dot seven", "1.2.6; minus one dot two dot six; 1.2.7"),
            ("Keep one dot two dot six dot beta; use one dot two dot seven.", "Keep one dot two dot six dot beta; use 1.2.7."),
            ("one dot two dot six and 42 people", "1.2.6 and 42 people"),
            ("one dot two dot six and six people", "1.2.6 and six people"),
            ("Use one dot two dot six and one hundred examples.", "Use 1.2.6 and one hundred examples."),
            ("one dot two dot six and a million thanks", "1.2.6 and a million thanks"),
            ("one dot two dot six... then stop.", "1.2.6... then stop."),
            ("one dot two dot six...", "1.2.6..."),
        ]
        let ambiguous = [
            // Decimals, dates, lists, fractions, and ordinary speech aren't versions.
            "The price is one point two six pounds, or 1.26.",
            "Meet on 01.02.2026 at 12:06; there are 1,206 seats.",
            "One dot. Two dots. Six people joined the dots.",
            "Use version one dot two, then stop.",
            "one dot two dot six and a half",
            "one dot two dot six hundredths",
            "one dot two dot six quadrillion",
            "one dot two dot six millions",
            "one dot two dot six and three quarters",
            "one dot two dot six and one half",
            "one dot two dot six and two thirds",
            "one dot two dot six and five hundredths",
            "one dot two dot six quintillion",
            // Never format only the valid part of an incomplete or malformed sequence.
            "one dot two dot six dot", "dot one dot two dot six",
            "one dot two dot six dot minus four", "one dot two dot six dot 4/5",
            "one dot two dot six..seven", "one dot two dot six.dot seven",
            "one dot two dot six dot twenty thirteen",
            "twenty thirteen dot one dot two dot three",
            // Unicode signs and ranges carry meaning just like ASCII ones.
            "−one dot two dot six", "one dot two dot six−eight",
            "one dot two dot six–eight", "one dot two dot six‑eight",
            "one dot two dot six—eight",
            // Don't transform a portion of an identifier, path, URL, or labelled quantity.
            "one dot two dot six\\notes", "C:\\one dot two dot six",
            "one dot two dot six%", "one dot two dot six½",
            "$one dot two dot six", "£one dot two dot six",
            "one dot two dot six\u{200d}suffix", "prefix\u{200d}one dot two dot six",
            "one dot two dot six\u{301}", "one\u{301} dot two dot six",
        ]
        // Whitespace that ends a line must never join version components.
        let lineBreaks = ["\n", "\r", "\r\n", "\u{b}", "\u{c}", "\u{85}", "\u{2028}", "\u{2029}"]
        let brokenLines = lineBreaks.flatMap { ["one dot two dot\($0)six", "one\($0)dot two dot six"] }
        // Formatting one span must not change any surrounding code points or offsets.
        let wrappers = [("", ""), ("(", ")"), ("[", "]"), ("\"", "\""), ("👩🏽‍💻 ", " e\u{301} ✅"), ("\t", "\r\n")]
        var wrapped: [(String, String)] = []
        for (prefix, suffix) in wrappers {
            wrapped.append(("\(prefix)one dot two dot six\(suffix)", "\(prefix)1.2.6\(suffix)"))
            wrapped.append(("\(prefix)one dot two\(suffix)", "\(prefix)one dot two\(suffix)"))
        }
        var fixtures = versions + sentences + wrapped
        fixtures += (unchanged + ambiguous + brokenLines).map { ($0, $0) }
        for (input, expected) in fixtures {
            let actual = VersionNumberFormatter.format(input)
            // String equality allows canonically equivalent Unicode; these checks
            // require untouched text to retain its exact encoding too.
            if !actual.utf8.elementsEqual(expected.utf8) {
                failures.append("Version formatting: \(String(reflecting: input)) → \(String(reflecting: actual)); expected \(String(reflecting: expected))")
            }
            if !VersionNumberFormatter.format(actual).utf8.elementsEqual(actual.utf8) {
                failures.append("Version formatting must be idempotent: \(String(reflecting: input))")
            }
        }
        guard failures.isEmpty else { throw Failure(messages: failures) }
        print("PASS: \(fixtures.count) version-formatting cases, exact preservation, and idempotence")
    }

    private struct Failure: Error, CustomStringConvertible {
        let messages: [String]
        var description: String { messages.joined(separator: "\n") }
    }
}
