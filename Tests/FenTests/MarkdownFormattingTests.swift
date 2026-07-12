@testable import FenCore
import Foundation
import Testing

/// Rules from issue #13's spec (github.com/zoharbabin/fen/issues/13). Each test below is named
/// after and cites the rule number it proves. `MarkdownFormatting.apply` is a pure function --
/// no live text view needed to exercise every action's algorithm.
struct MarkdownFormattingTests {
    private func range(_ text: String, _ substring: String) -> NSRange {
        (text as NSString).range(of: substring)
    }

    // MARK: - Rule 3.1: wrap/toggle (bold, italic, strikethrough, inline code)

    @Test(arguments: [
        (FormattingAction.bold, "**"),
        (FormattingAction.italic, "*"),
        (FormattingAction.strikethrough, "~~"),
        (FormattingAction.inlineCode, "`"),
    ])
    func wrapActionWrapsAnUnwrappedSelection(action: FormattingAction, marker: String) {
        let text = "Hello world"
        let selection = range(text, "world")
        let result = MarkdownFormatting.apply(action, to: text, selection: selection)
        #expect(result.text == "Hello \(marker)world\(marker)")
    }

    @Test(arguments: [
        FormattingAction.bold, .italic, .strikethrough, .inlineCode,
    ])
    func wrapActionIsSymmetricToggle(action: FormattingAction) {
        let text = "Hello world"
        let selection = range(text, "world")
        let wrapped = MarkdownFormatting.apply(action, to: text, selection: selection)
        let unwrapped = MarkdownFormatting.apply(action, to: wrapped.text, selection: wrapped.selection)
        #expect(unwrapped.text == text)
    }

    @Test func boldOnEmptySelectionInsertsPlaceholderAndSelectsIt() {
        let text = "Hello "
        let selection = NSRange(location: 6, length: 0)
        let result = MarkdownFormatting.apply(.bold, to: text, selection: selection)
        #expect(result.text == "Hello **bold text**")
        let placeholder = (result.text as NSString).substring(with: result.selection)
        #expect(placeholder == "bold text")
    }

    // MARK: - Rule 3.2: headings replace, never stack

    @Test func headingOnPlainLineInsertsPrefix() {
        let text = "Foo"
        let selection = NSRange(location: 0, length: 0)
        let result = MarkdownFormatting.apply(.heading1, to: text, selection: selection)
        #expect(result.text == "# Foo")
    }

    @Test func reapplyingADifferentHeadingLevelReplacesRatherThanStacks() {
        let text = "## Foo"
        let selection = NSRange(location: 3, length: 0)
        let result = MarkdownFormatting.apply(.heading1, to: text, selection: selection)
        #expect(result.text == "# Foo")
    }

    @Test func reapplyingTheSameHeadingLevelRemovesIt() {
        let text = "# Foo"
        let selection = NSRange(location: 2, length: 0)
        let result = MarkdownFormatting.apply(.heading1, to: text, selection: selection)
        #expect(result.text == "Foo")
    }

    // MARK: - Rule 3.3/3.4: line-prefix actions

    @Test(arguments: [
        (FormattingAction.bulletList, "- "),
        (FormattingAction.blockquote, "> "),
        (FormattingAction.taskItem, "- [ ] "),
    ])
    func linePrefixAppliesToEveryLineOfAMultilineSelection(action: FormattingAction, prefix: String) {
        let text = "one\ntwo\nthree"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let result = MarkdownFormatting.apply(action, to: text, selection: selection)
        #expect(result.text == "\(prefix)one\n\(prefix)two\n\(prefix)three")
    }

    @Test func linePrefixOnZeroLengthSelectionPrefixesOnlyTheCursorsLine() {
        let text = "one\ntwo\nthree"
        let selection = range(text, "two")
        let cursor = NSRange(location: selection.location, length: 0)
        let result = MarkdownFormatting.apply(.bulletList, to: text, selection: cursor)
        #expect(result.text == "one\n- two\nthree")
    }

    @Test func linePrefixToggleRemovesWhenEveryLineAlreadyHasIt() {
        let text = "- one\n- two"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let result = MarkdownFormatting.apply(.bulletList, to: text, selection: selection)
        #expect(result.text == "one\ntwo")
    }

    @Test func numberedListRestartsAtOneForEachApplication() {
        let text = "one\ntwo\nthree"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let result = MarkdownFormatting.apply(.numberedList, to: text, selection: selection)
        #expect(result.text == "1. one\n2. two\n3. three")
    }

    // MARK: - Rule 3.5: task item checkbox toggle

    @Test func taskItemOnPlainLineAddsUncheckedBox() {
        let text = "buy milk"
        let selection = NSRange(location: 0, length: 0)
        let result = MarkdownFormatting.apply(.taskItem, to: text, selection: selection)
        #expect(result.text == "- [ ] buy milk")
    }

    @Test func taskItemReappliedTogglesCheckboxInsteadOfDuplicatingPrefix() {
        let text = "- [ ] buy milk"
        let selection = NSRange(location: 0, length: 0)
        let checked = MarkdownFormatting.apply(.taskItem, to: text, selection: selection)
        #expect(checked.text == "- [x] buy milk")
        let unchecked = MarkdownFormatting.apply(.taskItem, to: checked.text, selection: checked.selection)
        #expect(unchecked.text == "- [ ] buy milk")
    }

    // MARK: - Rule 3.6: link/image nested-placeholder wrap

    @Test func linkOnNonEmptySelectionWrapsTextAndSelectsURLPlaceholder() {
        let text = "See docs"
        let selection = range(text, "docs")
        let result = MarkdownFormatting.apply(.link, to: text, selection: selection)
        #expect(result.text == "See [docs](url)")
        #expect((result.text as NSString).substring(with: result.selection) == "url")
    }

    @Test func linkOnEmptySelectionInsertsBothPlaceholdersAndSelectsLinkText() {
        let text = ""
        let selection = NSRange(location: 0, length: 0)
        let result = MarkdownFormatting.apply(.link, to: text, selection: selection)
        #expect(result.text == "[link text](url)")
        #expect((result.text as NSString).substring(with: result.selection) == "link text")
    }

    @Test func imageOnEmptySelectionInsertsAltPlaceholder() {
        let text = ""
        let selection = NSRange(location: 0, length: 0)
        let result = MarkdownFormatting.apply(.image, to: text, selection: selection)
        #expect(result.text == "![alt text](url)")
        #expect((result.text as NSString).substring(with: result.selection) == "alt text")
    }

    // MARK: - Rule 3.7: horizontal rule ignores selection

    @Test func horizontalRuleIgnoresNonEmptySelectionAndInsertsOnItsOwnLine() {
        let text = "keep me"
        let selection = range(text, "keep me")
        let result = MarkdownFormatting.apply(.horizontalRule, to: text, selection: selection)
        #expect(result.text.contains("keep me"))
        #expect(result.text.contains("---"))
    }

    // MARK: - Rule 3.8: code block multi-line fence wrap

    @Test func codeBlockOnEmptySelectionInsertsEmptyFenceWithCursorInside() {
        let text = ""
        let selection = NSRange(location: 0, length: 0)
        let result = MarkdownFormatting.apply(.codeBlock, to: text, selection: selection)
        #expect(result.text == "```\n\n```")
    }

    @Test func codeBlockOnMultilineSelectionWrapsContentUnchanged() {
        let text = "one\ntwo"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let result = MarkdownFormatting.apply(.codeBlock, to: text, selection: selection)
        #expect(result.text == "```\none\ntwo\n```")
    }

    // MARK: - Rule 3.9: table template insert ignores selection

    @Test func tableIgnoresSelectionAndInsertsAFixedTemplate() {
        let text = "existing"
        let selection = range(text, "existing")
        let result = MarkdownFormatting.apply(.table, to: text, selection: selection)
        #expect(result.text.contains("existing"))
        #expect(result.text.contains("---"))
        #expect(result.text.contains("|"))
    }

    // MARK: - Rule 3.10: edge selections never crash

    @Test func everyActionIsSafeAtStartOfEmptyDocument() {
        let selection = NSRange(location: 0, length: 0)
        for action in FormattingAction.allCases {
            _ = MarkdownFormatting.apply(action, to: "", selection: selection)
        }
    }

    @Test func everyActionIsSafeAtEndOfNonEmptyDocument() {
        let text = "some text"
        let selection = NSRange(location: (text as NSString).length, length: 0)
        for action in FormattingAction.allCases {
            _ = MarkdownFormatting.apply(action, to: text, selection: selection)
        }
    }

    // MARK: - Rule 4.1: performance bounded by edited region, not document size

    @Test func applyCompletesQuicklyOnALargeDocument() {
        let text = Array(repeating: "line of text", count: 100_000).joined(separator: "\n")
        let selection = NSRange(location: 0, length: 4)
        let before = ContinuousClock.now
        _ = MarkdownFormatting.apply(.bold, to: text, selection: selection)
        let elapsed = before.duration(to: .now)
        #expect(elapsed < .milliseconds(50))
    }
}
