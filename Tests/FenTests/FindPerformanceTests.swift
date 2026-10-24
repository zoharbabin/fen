@testable import FenCore
import Foundation
import Testing

/// Budgets for the work that runs on every keystroke. The printed numbers are the measurements.
@Suite("Find performance")
struct FindPerformanceTests {
    /// About 1 MB of prose-like text with a known number of hits.
    private static let document: String = {
        let line = "The quick brown fox jumps over the lazy dog while résumé and naïve café wait. "
        return (0 ..< 13000).map { _ in line }.joined(separator: "\n")
    }()

    private func median(of runs: Int, _ work: () throws -> Void) throws -> Duration {
        var times: [Duration] = []
        for _ in 0 ..< runs {
            let started = ContinuousClock.now
            try work()
            times.append(ContinuousClock.now - started)
        }
        return times.sorted()[runs / 2]
    }

    @Test("a literal search of 1 MB with thousands of hits is fast")
    func literal() throws {
        let text = Self.document
        #expect(text.utf16.count > 900_000)
        let time = try median(of: 5) {
            let result = try FindEngine.find(FindQuery(text: "fox"), in: text)
            #expect(result.ranges.count == 13000)
        }
        print("PERF literal fox, 1 MB, 13000 hits:", time)
        #expect(time < .milliseconds(250))
    }

    @Test("an accent-insensitive search stays fast")
    func accents() throws {
        let text = Self.document
        let time = try median(of: 5) {
            let result = try FindEngine.find(FindQuery(text: "resume"), in: text)
            #expect(result.ranges.count == 13000)
        }
        print("PERF accent-insensitive resume, 1 MB:", time)
        #expect(time < .milliseconds(400))
    }

    @Test("whole word and regex searches stay fast")
    func wholeWordAndRegex() throws {
        let text = Self.document
        let word = try median(of: 3) {
            let ranges = try FindEngine.find(FindQuery(text: "the", wholeWord: true), in: text).ranges
            #expect(ranges.count == 26000)
        }
        let regex = try median(of: 3) {
            let ranges = try FindEngine.find(FindQuery(text: "qu\\w+", isRegex: true), in: text).ranges
            #expect(ranges.count == 13000)
        }
        print("PERF whole word the:", word, "regex qu\\w+:", regex)
        #expect(word < .milliseconds(600))
        #expect(regex < .milliseconds(600))
    }

    @Test("a one-letter query is capped and still returns quickly")
    func oneLetter() throws {
        let text = Self.document
        let time = try median(of: 3) {
            let result = try FindEngine.find(FindQuery(text: "e"), in: text)
            #expect(result.isTruncated)
        }
        print("PERF one letter, capped:", time)
        #expect(time < .milliseconds(400))
    }

    @Test("a missing word scans 1 MB quickly")
    func miss() throws {
        let text = Self.document
        let time = try median(of: 5) {
            let ranges = try FindEngine.find(FindQuery(text: "zebra"), in: text).ranges
            #expect(ranges.isEmpty)
        }
        print("PERF miss, 1 MB:", time)
        #expect(time < .milliseconds(150))
    }

    @Test("Did you mean scans 1 MB in a blink")
    func suggestion() throws {
        let text = Self.document
        let time = try median(of: 3) {
            #expect(FindSuggestion.nearest(to: "wiat", in: text) == "wait")
        }
        print("PERF suggestion, 1 MB:", time)
        #expect(time < .milliseconds(1500))
    }
}
