@testable import FenCore
import Foundation
import Testing

@Suite("Find engine")
struct FindEngineTests {
    private func found(
        _ text: String, _ query: String, regex: Bool = false, word: Bool = false, matchCase: Bool = false,
        within scope: NSRange? = nil
    ) throws -> [String] {
        let q = FindQuery(text: query, isRegex: regex, wholeWord: word, matchCase: matchCase)
        let result = try FindEngine.find(q, in: text, within: scope)
        return result.ranges.map { (text as NSString).substring(with: $0) }
    }

    // MARK: Case

    @Test("a lowercase query ignores case")
    func lowercaseIgnoresCase() throws {
        #expect(try found("Fen fen FEN", "fen") == ["Fen", "fen", "FEN"])
    }

    @Test("a capital in the query matches exactly (smart case)")
    func capitalIsExact() throws {
        #expect(try found("Fen fen FEN", "Fen") == ["Fen"])
    }

    @Test("Match Case makes a lowercase query exact")
    func matchCaseToggle() throws {
        #expect(try found("Fen fen FEN", "fen", matchCase: true) == ["fen"])
    }

    @Test("regex escapes like \\W do not count as typed capitals")
    func regexEscapesAreNotCapitals() {
        #expect(!FindEngine.isCaseSensitive(FindQuery(text: "a\\Wb", isRegex: true)))
        #expect(FindEngine.isCaseSensitive(FindQuery(text: "A\\Wb", isRegex: true)))
    }

    // MARK: Accents and width

    @Test("accents are ignored unless the query has one")
    func accents() throws {
        #expect(try found("resume résumé", "resume") == ["resume", "résumé"])
        #expect(try found("resume résumé", "résumé") == ["résumé"])
    }

    @Test("decomposed accents in the query count as accents")
    func decomposedAccent() throws {
        #expect(try found("resume résumé", "re\u{301}sume\u{301}") == ["résumé"])
    }

    @Test("full-width forms match their ASCII twins")
    func width() throws {
        #expect(try found("ＡＢＣ abc", "abc") == ["ＡＢＣ", "abc"])
    }

    // MARK: Literal behavior

    @Test("regex characters are literal until regex is on")
    func literalByDefault() throws {
        #expect(try found("a.c abc (x) [y]", "a.c") == ["a.c"])
        #expect(try found("a.c abc (x) [y]", "(x)") == ["(x)"])
    }

    @Test("overlapping hits count once")
    func overlaps() throws {
        #expect(try found("aaaa", "aa").count == 2)
        #expect(try found("aaa", "aa").count == 1)
    }

    @Test("an empty query finds nothing")
    func emptyQuery() throws {
        #expect(try found("abc", "").isEmpty)
    }

    @Test("a query can span a newline")
    func multiline() throws {
        #expect(try found("one\ntwo", "one\ntwo") == ["one\ntwo"])
    }

    @Test("emoji and other surrogate pairs match whole")
    func surrogates() throws {
        let text = "a 😀 b 😀"
        let q = FindQuery(text: "😀")
        let ranges = try FindEngine.find(q, in: text).ranges
        #expect(ranges == [NSRange(location: 2, length: 2), NSRange(location: 7, length: 2)])
    }

    // MARK: Whole word

    @Test("whole word skips hits inside longer words")
    func wholeWord() throws {
        #expect(try found("cat concatenate cat. cats cat_ cat", "cat", word: true).count == 3)
    }

    @Test("whole word finds a real hit that sits after a partial one")
    func wholeWordAfterPartial() throws {
        #expect(try found("concatenate cat", "cat", word: true).count == 1)
    }

    @Test("whole word uses Unicode letters")
    func wholeWordUnicode() throws {
        #expect(try found("naïve naïvety", "naïve", word: true).count == 1)
        #expect(try found("日本語 日本", "日本", word: true).count == 1)
    }

    @Test("whole word on a query that starts with punctuation still works")
    func wholeWordPunctuation() throws {
        #expect(try found("call foo() now, foo()x", "foo()", word: true).count == 2)
    }

    // MARK: Regex

    @Test("regex finds patterns and ^ matches every line")
    func regexBasics() throws {
        #expect(try found("a1 b22 c333", "[a-z]\\d+", regex: true) == ["a1", "b22", "c333"])
        #expect(try found("x\ny\nz", "^.", regex: true) == ["x", "y", "z"])
    }

    @Test("regex honors smart case")
    func regexSmartCase() throws {
        #expect(try found("Foo foo", "foo", regex: true).count == 2)
        #expect(try found("Foo foo", "Foo", regex: true).count == 1)
    }

    @Test("regex whole word wraps the whole pattern")
    func regexWholeWord() throws {
        #expect(try found("cat|dog catdog dog", "cat|dog", regex: true, word: true) == ["cat", "dog", "dog"])
    }

    @Test("an invalid pattern throws, a literal with the same text does not")
    func invalidRegex() throws {
        #expect(throws: FindError.invalidPattern) { try found("a(b", "(", regex: true) }
        #expect(try found("a(b", "(") == ["("])
    }

    @Test("zero-length regex matches are not reported")
    func zeroLength() throws {
        #expect(try found("abc", "x*", regex: true).isEmpty)
    }

    // MARK: Scope and limits

    @Test("find in selection stays inside the scope")
    func scoped() throws {
        let text = "fen fen fen"
        #expect(try found(text, "fen", within: NSRange(location: 4, length: 3)).count == 1)
        #expect(try found(text, "fen", within: NSRange(location: 3, length: 4)).count == 1)
    }

    @Test("a scope past the end is clamped")
    func scopeClamped() throws {
        #expect(try found("fen", "fen", within: NSRange(location: 0, length: 999)).count == 1)
    }

    @Test("the match count is capped")
    func cap() throws {
        let text = String(repeating: "a ", count: FindEngine.maxMatches + 10)
        let result = try FindEngine.find(FindQuery(text: "a"), in: text)
        #expect(result.ranges.count == FindEngine.maxMatches)
        #expect(result.isTruncated)
    }

    @Test("a stop request ends the search early")
    func stops() throws {
        let text = String(repeating: "word ", count: 20000)
        var polls = 0
        let result = try FindEngine.find(FindQuery(text: "word"), in: text) {
            polls += 1
            return polls > 1
        }
        #expect(result.ranges.count < 20000)
    }

    @Test("a runaway regex stops when asked")
    func runawayRegex() throws {
        let text = String(repeating: "a", count: 40) + "b"
        let started = ContinuousClock.now
        _ = try FindEngine.find(FindQuery(text: "(a+)+$", isRegex: true), in: text) {
            ContinuousClock.now - started > .milliseconds(200)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // MARK: Replace

    private func replaced(
        _ text: String, _ query: FindQuery, _ template: String, keepCase: Bool = false
    ) throws -> [String] {
        let ranges = try FindEngine.find(query, in: text).ranges
        return try FindEngine.replacements(for: ranges, in: text, query: query, template: template, keepCase: keepCase)
    }

    @Test("a literal replacement is used as typed, `$1` included")
    func literalReplacement() throws {
        #expect(try replaced("a b", FindQuery(text: "a"), "$1") == ["$1"])
    }

    @Test("a regex replacement expands groups")
    func regexReplacement() throws {
        let query = FindQuery(text: "(\\w+)@(\\w+)", isRegex: true)
        #expect(try replaced("me@fen you@app", query, "$2:$1") == ["fen:me", "app:you"])
    }

    @Test("a regex replacement sees lookbehind context")
    func lookbehindReplacement() throws {
        let query = FindQuery(text: "(?<=x)a", isRegex: true)
        #expect(try replaced("xa ya", query, "B") == ["B"])
    }

    @Test("a regex replacement inside a selection expands groups the same way the search matched")
    func scopedRegexReplacement() throws {
        let text = "x1234"
        let scope = NSRange(location: 0, length: 3)
        let query = FindQuery(text: "x(\\d+)", isRegex: true)
        let ranges = try FindEngine.find(query, in: text, within: scope).ranges
        let strings = try FindEngine.replacements(
            for: ranges, in: text, query: query, template: "y$1", keepCase: false, within: scope
        )
        #expect(strings == ["y12"])
    }

    @Test("keep case copies the match's capitalization")
    func keepCase() throws {
        let query = FindQuery(text: "fen")
        #expect(try replaced("fen Fen FEN fEn", query, "owl", keepCase: true) == ["owl", "Owl", "OWL", "owl"])
    }

    @Test("keep case is off by default")
    func keepCaseOff() throws {
        #expect(try replaced("FEN", FindQuery(text: "fen"), "owl") == ["owl"])
    }
}
