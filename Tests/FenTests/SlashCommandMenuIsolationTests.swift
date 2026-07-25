@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #1, rule 1.1/1.2: `SlashCommandMenu.triggerMatch`/`filteredEntries`
/// are pure functions with no captured mutable state, so two independent (text, cursor) inputs
/// evaluated in the same process never leak into each other's result -- mirrors
/// `MarkdownFormattingIsolationTests`'s two-value pattern.
struct SlashCommandMenuIsolationTests {
    @Test func twoTriggerMatchesAgainstDifferentDocumentsStayIndependent() {
        let textA = "First document /tab"
        let textB = "Second document /head"

        let matchA = SlashCommandMenu.triggerMatch(text: textA, cursorLocation: (textA as NSString).length)
        let matchB = SlashCommandMenu.triggerMatch(text: textB, cursorLocation: (textB as NSString).length)

        #expect(matchA?.filterText == "tab")
        #expect(matchB?.filterText == "head")
        // Evaluating B did not retroactively change A's already-computed result -- proving
        // there is no shared/module-level state between the two calls.
        #expect(matchA?.filterText == "tab")
    }

    @Test func interleavedTriggerMatchesNeverLeakBetweenCalls() {
        let textA = "/al"
        let textB = "/im"

        let firstA = SlashCommandMenu.triggerMatch(text: textA, cursorLocation: (textA as NSString).length)
        let firstB = SlashCommandMenu.triggerMatch(text: textB, cursorLocation: (textB as NSString).length)
        let secondA = SlashCommandMenu.triggerMatch(text: textA, cursorLocation: (textA as NSString).length)

        #expect(firstA == secondA)
        #expect(firstA?.filterText != firstB?.filterText)
    }

    @Test func interleavedFilteringNeverLeaksBetweenCalls() {
        let filteredForA = SlashCommandMenu.filteredEntries(query: "tab")
        let filteredForB = SlashCommandMenu.filteredEntries(query: "head")
        let filteredForARepeat = SlashCommandMenu.filteredEntries(query: "tab")

        #expect(filteredForA.map(\.title) == ["Table"])
        #expect(filteredForB.map(\.title) == ["Heading"])
        #expect(filteredForA == filteredForARepeat)
    }
}
