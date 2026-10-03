import Foundation

/// Formats explicit dotted number sequences only; this is not a general text rewrite.
enum VersionNumberFormatter {
    private static let small: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
                               "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let separator = try! NSRegularExpression(pattern: #"\h+dot\h+|\."#, options: .caseInsensitive)
    private static let candidates: NSRegularExpression = {
        // Include unsupported large scales so an unparseable component is skipped
        // whole, rather than converting just its numeric prefix.
        let words = (Array(small.keys) + Array(tens.keys) + ["thousand", "million", "billion", "trillion"]).sorted().joined(separator: "|")
        let remainder = (small.filter { $0.value > 0 }.map(\.key) + Array(tens.keys)).sorted().joined(separator: "|")
        let hundred = #"hundred(?:\h+and(?=\h+(?:"# + remainder + #")(?![\p{L}\p{M}\p{N}_])))?"#
        let atom = #"(?:[0-9]+|"# + hundred + "|" + words + #")(?![\p{L}\p{M}\p{N}_])"#
        let component = atom + #"(?:[\h-]+"# + atom + #")*"#
        // Signs, currency, path separators, and invisible joiners can make this
        // part of a larger token. A period may end a sentence, so check it below.
        let adjacent = #"[\p{L}\p{M}\p{N}\p{Cf}\p{Pd}\p{Sc}_/\\@+−%‰]"#
        let pattern = "(?<!" + adjacent + #")(?<!\.)"# + component
            + #"(?:(?:\h+dot\h+|\.)"# + component + "){2,}(?!" + adjacent + ")"
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    private static let previousWord = try! NSRegularExpression(pattern: #"([\p{L}]+)\h*$"#)
    private static let followingDot = try! NSRegularExpression(
        pattern: #"^(?:\h+dot\b|\.+[\p{L}\p{M}\p{N}\p{Cf}_])"#, options: .caseInsensitive)
    // A fractional or large-scale continuation makes the last component ambiguous.
    // Keep the whole phrase instead of turning just its integer prefix into a version.
    private static let numberContinuation: NSRegularExpression = {
        let scale = #"(?:hundred|thousand|million|billion|trillion|quadrillion|quintillion)"#
        let fraction = #"(?:half|halves|quarters?|thirds?|fourths?|fifths?|sixths?|sevenths?|eighths?|ninths?|tenths?|"# + scale + #"ths?)"#
        let fractionPrefix = #"(?:and\h+)?(?:(?:a|one|two|three|four|five|six|seven|eight|nine)\h+)?"#
        // "...six and one hundred examples" is independent prose; only a
        // fractional continuation may include "and" or a numerator here.
        let pattern = #"^\h+(?:"# + fractionPrefix + fraction + "|" + scale + #"s?)\b"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    static func format(_ text: String) -> String {
        let source = text as NSString
        var result = text
        // Reverse replacements keep the original UTF-16 ranges valid, including
        // transcripts containing emoji and multiple version numbers.
        for match in candidates.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let candidate = source.substring(with: match.range)
            guard candidate.lowercased().contains("dot") else { continue }
            let before = source.substring(to: match.range.location)
            let after = source.substring(from: NSMaxRange(match.range))
            if let word = previousWord.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) {
                let value = (before as NSString).substring(with: word.range(at: 1)).lowercased()
                if ["dot", "minus", "negative", "plus"].contains(value) { continue }
            }
            // Never format a prefix/suffix of a longer unsupported dotted sequence.
            guard followingDot.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) == nil else { continue }
            guard numberContinuation.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) == nil else { continue }
            let components = separator.stringByReplacingMatches(in: candidate,
                range: NSRange(candidate.startIndex..., in: candidate), withTemplate: "|").components(separatedBy: "|")
            let numbers = components.compactMap(number)
            guard numbers.count == components.count, let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: numbers.joined(separator: "."))
        }
        return result
    }

    private static func number(_ component: String) -> String? {
        // Only conventional tens compounds use a hyphen. Do not reinterpret
        // "six-eight" as digit-by-digit dictation or a version range.
        for compound in component.lowercased().split(whereSeparator: \.isWhitespace) where compound.contains("-") {
            let parts = compound.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, tens[String(parts[0])] != nil,
                  let unit = small[String(parts[1])], (1...9).contains(unit) else { return nil }
        }
        let words = component.lowercased().split { $0.isWhitespace || $0 == "-" }.map(String.init)
        if words.count == 1, words[0].utf8.allSatisfy({ (48...57).contains($0) }) { return words[0] }
        // Digit-by-digit dictation keeps leading zeroes: "zero zero six" → "006".
        let digits = words.compactMap { small[$0].flatMap { $0 < 10 ? String($0) : nil } }
        if digits.count == words.count { return digits.joined() }
        if words.count >= 2, let hundreds = small[words[0]], (1...9).contains(hundreds), words[1] == "hundred" {
            var tail = Array(words.dropFirst(2))
            if tail.first == "and" {
                tail.removeFirst()
                guard !tail.isEmpty else { return nil }
            }
            guard let remainder = tail.isEmpty ? 0 : underHundred(tail), tail.isEmpty || remainder > 0 else { return nil }
            return String(hundreds * 100 + remainder)
        }
        return underHundred(words).map(String.init)
    }

    private static func underHundred(_ words: [String]) -> Int? {
        if words.count == 1 { return small[words[0]] ?? tens[words[0]] }
        if words.count == 2, let tens = tens[words[0]], let unit = small[words[1]], (1...9).contains(unit) {
            return tens + unit
        }
        return nil
    }
}
