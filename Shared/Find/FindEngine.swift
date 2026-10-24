import Foundation

/// What the user typed in the find bar, plus the toggles that change how it matches.
public struct FindQuery: Equatable, Sendable {
    public var text: String
    public var isRegex: Bool
    public var wholeWord: Bool
    /// Off means smart case: an all-lowercase query ignores case, any capital matches exactly.
    public var matchCase: Bool

    public init(text: String = "", isRegex: Bool = false, wholeWord: Bool = false, matchCase: Bool = false) {
        self.text = text
        self.isRegex = isRegex
        self.wholeWord = wholeWord
        self.matchCase = matchCase
    }

    public var isEmpty: Bool {
        text.isEmpty
    }
}

public struct FindResult: Equatable, Sendable {
    public var ranges: [NSRange]
    /// True when the search stopped at `FindEngine.maxMatches`.
    public var isTruncated: Bool
}

public enum FindError: Error, Equatable {
    case invalidPattern
}

/// The editor's matcher. Pure and synchronous, so it runs off the main thread and tests without a view.
/// Literal queries ignore accents and width unless the query itself has an accent. Regex queries use ICU.
public enum FindEngine {
    public static let maxMatches = 50000

    /// Smart case. A capital letter in a literal query makes it case-sensitive. In a regex, escapes such as
    /// `\W` or `\S` are not capitals the user typed, so they are skipped.
    public static func isCaseSensitive(_ query: FindQuery) -> Bool {
        if query.matchCase {
            return true
        }
        var skipNext = false
        for character in query.text {
            if skipNext {
                skipNext = false
                continue
            }
            if query.isRegex, character == "\\" {
                skipNext = true
                continue
            }
            if character.isUppercase {
                return true
            }
        }
        return false
    }

    /// Every match in `scope` (the whole text by default). `shouldStop` is polled so a superseded search ends early.
    public static func find(
        _ query: FindQuery,
        in text: String,
        within scope: NSRange? = nil,
        shouldStop: () -> Bool = { false }
    ) throws -> FindResult {
        guard !query.isEmpty else { return FindResult(ranges: [], isTruncated: false) }
        let string = text as NSString
        let range = scope.map { NSIntersectionRange($0, NSRange(location: 0, length: string.length)) }
            ?? NSRange(location: 0, length: string.length)
        if query.isRegex {
            return try regexMatches(query, in: string, range: range, shouldStop: shouldStop)
        }
        return literalMatches(query, in: string, range: range, shouldStop: shouldStop)
    }

    // MARK: - Literal

    private static func literalMatches(
        _ query: FindQuery, in string: NSString, range: NSRange, shouldStop: () -> Bool
    ) -> FindResult {
        var options: NSString.CompareOptions = [.widthInsensitive]
        if !isCaseSensitive(query) {
            options.insert(.caseInsensitive)
        }
        if !hasAccent(query.text) {
            options.insert(.diacriticInsensitive)
        }
        var ranges: [NSRange] = []
        var searchFrom = range.location
        let end = NSMaxRange(range)
        var checked = 0
        while searchFrom < end {
            checked += 1
            if checked % 256 == 0, shouldStop() {
                break
            }
            let found = string.range(
                of: query.text, options: options, range: NSRange(location: searchFrom, length: end - searchFrom)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            // Overlaps are skipped, as every editor does: "aa" in "aaa" is one match.
            searchFrom = NSMaxRange(found)
            if query.wholeWord, !isWholeWord(found, in: string) {
                // A partial hit can hide a real one inside it ("cat" in "concatenate cat"), so step by one.
                searchFrom = found.location + 1
                continue
            }
            ranges.append(found)
            if ranges.count >= maxMatches {
                return FindResult(ranges: ranges, isTruncated: true)
            }
        }
        return FindResult(ranges: ranges, isTruncated: false)
    }

    /// A match is a whole word when its edges don't touch a word character. An edge that is itself
    /// punctuation (`foo(`) has nothing to be bounded against, so it passes.
    static func isWholeWord(_ range: NSRange, in string: NSString) -> Bool {
        let beforeOK = range.location == 0
            || !isWordCharacter(string.substring(with: string.rangeOfComposedCharacterSequence(at: range.location - 1)))
            || !isWordCharacter(string.substring(with: string.rangeOfComposedCharacterSequence(at: range.location)))
        let end = NSMaxRange(range)
        let afterOK = end >= string.length
            || !isWordCharacter(string.substring(with: string.rangeOfComposedCharacterSequence(at: end)))
            || !isWordCharacter(string.substring(with: string.rangeOfComposedCharacterSequence(at: end - 1)))
        return beforeOK && afterOK
    }

    private static func isWordCharacter(_ piece: String) -> Bool {
        guard let character = piece.first else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    private static func hasAccent(_ text: String) -> Bool {
        text.decomposedStringWithCanonicalMapping.unicodeScalars.contains {
            $0.properties.generalCategory == .nonspacingMark
        }
    }

    // MARK: - Regex

    static func regex(for query: FindQuery) throws -> NSRegularExpression {
        var pattern = query.text
        if query.wholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])"
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines, .useUnicodeWordBoundaries]
        if !isCaseSensitive(query) {
            options.insert(.caseInsensitive)
        }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw FindError.invalidPattern
        }
    }

    private static func regexMatches(
        _ query: FindQuery, in string: NSString, range: NSRange, shouldStop: () -> Bool
    ) throws -> FindResult {
        let expression = try regex(for: query)
        var ranges: [NSRange] = []
        var truncated = false
        // `.reportProgress` calls the block during long backtracking too, so a runaway pattern can be stopped.
        expression
            .enumerateMatches(in: string as String, options: [.reportProgress], range: range) { match, flags, stop in
                if shouldStop() {
                    stop.pointee = true
                    return
                }
                guard flags.isDisjoint(with: .progress), let match, match.range.length > 0 else { return }
                ranges.append(match.range)
                if ranges.count >= maxMatches {
                    truncated = true
                    stop.pointee = true
                }
            }
        return FindResult(ranges: ranges, isTruncated: truncated)
    }

    // MARK: - Replace

    /// The replacement text for each of `ranges`, which must be matches `find` returned for `query` in `scope`.
    /// A regex template expands `$1`, `$&` and `\$` as ICU defines them. `keepCase` copies the match's
    /// capitalization onto the result.
    public static func replacements(
        for ranges: [NSRange], in text: String, query: FindQuery, template: String, keepCase: Bool,
        within scope: NSRange? = nil
    ) throws -> [String] {
        let string = text as NSString
        // Matched again over the same scope `find` used, so edges (`\b`, lookbehind) resolve the same way.
        var matches: [Int: NSTextCheckingResult] = [:]
        let expression = query.isRegex ? try regex(for: query) : nil
        if let expression {
            let range = scope.map { NSIntersectionRange($0, NSRange(location: 0, length: string.length)) }
                ?? NSRange(location: 0, length: string.length)
            expression.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                if let match {
                    matches[match.range.location] = match
                }
            }
        }
        return ranges.map { range in
            var result = template
            if let expression, let match = matches[range.location], match.range == range {
                result = expression.replacementString(for: match, in: text, offset: 0, template: template)
            }
            return keepCase ? matchingCase(of: string.substring(with: range), applyTo: result) : result
        }
    }

    /// `Foo` → `Bar`, `FOO` → `BAR`, `foo` → `bar`. Mixed case such as `fOo` is left as typed.
    static func matchingCase(of match: String, applyTo replacement: String) -> String {
        let letters = match.filter(\.isLetter)
        guard let first = letters.first else { return replacement }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) {
            return replacement.uppercased()
        }
        if letters.allSatisfy(\.isLowercase) {
            return replacement.lowercased()
        }
        if first.isUppercase, letters.dropFirst().allSatisfy(\.isLowercase) {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
