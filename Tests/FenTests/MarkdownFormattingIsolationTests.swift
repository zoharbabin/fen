@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #13: proves `MarkdownFormatting.apply` holds no shared mutable
/// state across calls, per rule 1.1 (per-instance/per-call state only, no module-level mutable
/// store) -- interleaves calls against two different texts/selections in one process and checks
/// neither call's result leaks into the other.
struct MarkdownFormattingIsolationTests {
    @Test func interleavedCallsAgainstDifferentTextsDoNotShareState() {
        let textA = "alpha text"
        let textB = "beta text"
        let selectionA = (textA as NSString).range(of: "alpha")
        let selectionB = (textB as NSString).range(of: "beta")

        let resultA1 = MarkdownFormatting.apply(.bold, to: textA, selection: selectionA)
        let resultB1 = MarkdownFormatting.apply(.italic, to: textB, selection: selectionB)
        let resultA2 = MarkdownFormatting.apply(.bold, to: textA, selection: selectionA)
        let resultB2 = MarkdownFormatting.apply(.italic, to: textB, selection: selectionB)

        #expect(resultA1.text == resultA2.text)
        #expect(resultB1.text == resultB2.text)
        #expect(resultA1.text == "**alpha** text")
        #expect(resultB1.text == "*beta* text")
    }

    @Test func repeatedCallsOnOneActionNeverAccumulateAcrossUnrelatedText() {
        var counter = 0
        var results: [String] = []
        for _ in 0 ..< 5 {
            counter += 1
            let text = "item \(counter)"
            let selection = (text as NSString).range(of: "item")
            results.append(MarkdownFormatting.apply(.bold, to: text, selection: selection).text)
        }
        #expect(results == ["**item** 1", "**item** 2", "**item** 3", "**item** 4", "**item** 5"])
    }
}
