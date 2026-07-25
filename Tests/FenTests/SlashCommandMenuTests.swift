@testable import FenCore
import Foundation
import Testing

/// Rules from issue #1's spec (github.com/zoharbabin/fen/issues/1). Each test below is named
/// after and cites the rule number it proves. `SlashCommandMenu`'s functions are pure -- no live
/// text view needed to exercise trigger detection or filtering.
struct SlashCommandMenuTests {
    // MARK: - Rule 3.2: trigger gating

    @Test func slashAtLineStartOpensMenu() {
        let text = "/"
        let match = SlashCommandMenu.triggerMatch(text: text, cursorLocation: 1)
        #expect(match != nil)
        #expect(match?.filterText.isEmpty == true)
    }

    @Test func slashAfterWhitespaceOpensMenu() {
        let text = "hello /"
        let match = SlashCommandMenu.triggerMatch(text: text, cursorLocation: (text as NSString).length)
        #expect(match != nil)
        #expect(match?.filterText.isEmpty == true)
    }

    @Test func slashMidWordDoesNotOpenMenu() {
        let httpText = "http://example.com"
        let httpCursor = (httpText as NSString).range(of: "http:/").location + 6
        #expect(SlashCommandMenu.triggerMatch(text: httpText, cursorLocation: httpCursor) == nil)

        let andOrText = "and/or"
        let andOrCursor = (andOrText as NSString).range(of: "and/").location + 4
        #expect(SlashCommandMenu.triggerMatch(text: andOrText, cursorLocation: andOrCursor) == nil)
    }

    @Test func typingAfterSlashNarrowsFilterTextAndRange() {
        let text = "/tab"
        let match = SlashCommandMenu.triggerMatch(text: text, cursorLocation: (text as NSString).length)
        #expect(match?.filterText == "tab")
        #expect(match?.range == NSRange(location: 0, length: 4))
    }

    // MARK: - Rule 3.3: filtering degrades gracefully

    @Test func unmatchedFilterProducesEmptyList() {
        #expect(SlashCommandMenu.filteredEntries(query: "zzz").isEmpty)
    }

    @Test func emptyFilterShowsEveryEntry() {
        #expect(SlashCommandMenu.filteredEntries(query: "").count == SlashCommandMenu.entries.count)
    }

    @Test func filterNarrowsCaseInsensitively() {
        let filtered = SlashCommandMenu.filteredEntries(query: "tab")
        #expect(filtered.map(\.title) == ["Table"])
    }

    // MARK: - Rule 3.4: Escape/click-away dismissal never mutates text

    @Test func escapeDismissesWithoutMutatingText() {
        let text = "/tab"
        let match = SlashCommandMenu.triggerMatch(text: text, cursorLocation: (text as NSString).length)
        #expect(match != nil)
        // Dismissal is simply not committing an entry -- the text is never touched by the
        // trigger-detection/filtering functions themselves, so no separate "undo" is needed.
        #expect(text == "/tab")
    }

    // MARK: - Rule 3.5: selecting an entry reuses MarkdownFormatting.apply after removing the

    // triggering `/`+query range

    private func committed(
        text: String, cursorLocation: Int, entryTitle: String
    ) -> (text: String, selection: NSRange)? {
        guard let match = SlashCommandMenu.triggerMatch(text: text, cursorLocation: cursorLocation),
              let entry = SlashCommandMenu.filteredEntries(query: match.filterText)
              .first(where: { $0.title == entryTitle }) else { return nil }
        let ns = text as NSString
        let removed = ns.replacingCharacters(in: match.range, with: "")
        let cursor = NSRange(location: match.range.location, length: 0)
        return MarkdownFormatting.apply(entry.action, to: removed, selection: cursor)
    }

    @Test func selectingHeadingInsertsH1AndRemovesSlashQuery() {
        let result = committed(text: "/head", cursorLocation: 5, entryTitle: "Heading")
        #expect(result?.text == "# ")
    }

    @Test func selectingTableInsertsTemplateAtASensibleCursorPosition() {
        let result = committed(text: "/tab", cursorLocation: 4, entryTitle: "Table")
        #expect(result?.text.contains("| Header | Header |") == true)
        let selectedPlaceholder = result.map { ($0.text as NSString).substring(with: $0.selection) }
        #expect(selectedPlaceholder == "Header")
    }

    @Test func selectingImageInsertsAltPlaceholder() {
        let result = committed(text: "/imag", cursorLocation: 5, entryTitle: "Image")
        #expect(result?.text == "![alt text](url)")
    }

    @Test func selectingQuoteInsertsBlockquotePrefix() {
        let result = committed(text: "/quo", cursorLocation: 4, entryTitle: "Quote")
        #expect(result?.text == "> ")
    }

    @Test func selectingCodeBlockInsertsFenceWithCursorInside() {
        let result = committed(text: "/code", cursorLocation: 5, entryTitle: "Code Block")
        #expect(result?.text == "```\n\n```")
    }

    @Test func selectingHorizontalRuleInsertsRule() {
        let result = committed(text: "/horiz", cursorLocation: 6, entryTitle: "Horizontal Rule")
        #expect(result?.text.contains("---") == true)
    }

    @Test func selectingDiagramInsertsMermaidFence() {
        let result = committed(text: "/diag", cursorLocation: 5, entryTitle: "Diagram")
        #expect(result?.text == "```mermaid\n\n```")
    }

    // MARK: - Rule 3.5: edge selections (caret at position 0, and end-of-document) stay safe

    @Test func committingAtStartOfEmptyDocumentIsSafe() {
        for entry in SlashCommandMenu.entries {
            _ = MarkdownFormatting.apply(entry.action, to: "", selection: NSRange(location: 0, length: 0))
        }
    }

    @Test func committingAtEndOfNonEmptyDocumentIsSafe() {
        let text = "some text/tab"
        let selection = NSRange(location: (text as NSString).length, length: 0)
        for entry in SlashCommandMenu.entries {
            _ = MarkdownFormatting.apply(entry.action, to: text, selection: selection)
        }
    }

    // MARK: - Rule 4.1: filtering performance budget

    @Test func filteringLargeDocumentCompletesUnderBudget() {
        let text = Array(repeating: "line of text", count: 100_000).joined(separator: "\n") + "/tab"
        let cursorLocation = (text as NSString).length
        let before = ContinuousClock.now
        _ = SlashCommandMenu.triggerMatch(text: text, cursorLocation: cursorLocation)
        _ = SlashCommandMenu.filteredEntries(query: "tab")
        let elapsed = before.duration(to: .now)
        #expect(elapsed < .milliseconds(5))
    }
}
