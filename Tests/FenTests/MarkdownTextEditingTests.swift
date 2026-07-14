@testable import FenCore
import Foundation
import Testing

/// Rules traced from MacDown's original ObjC implementation as part of the settings-audit pass
/// (issues #15, #16, #17, #51). `MarkdownTextEditing`'s functions are pure -- no live text view
/// needed to exercise every rule's algorithm.
struct MarkdownTextEditingTests {
    // MARK: - Tabs-to-spaces (issue #17)

    @Test("Tab at column 0 inserts a full stop's worth of spaces")
    func tabAtColumnZero() {
        #expect(MarkdownTextEditing.tabInsertion(atColumn: 0) == "    ")
    }

    @Test("Tab rounds up to the next 4-column stop, not a fixed count", arguments: [
        (1, 3), (2, 2), (3, 1), (4, 4), (5, 3),
    ])
    func tabRoundsToNextStop(column: Int, expectedSpaces: Int) {
        #expect(MarkdownTextEditing.tabInsertion(atColumn: column).count == expectedSpaces)
    }

    @Test("Backspace outdents a full stop's worth of trailing spaces at once")
    func outdentRemovesFullStop() {
        #expect(MarkdownTextEditing.outdentAmount(linePrefix: "    ") == 4)
        #expect(MarkdownTextEditing.outdentAmount(linePrefix: "        ") == 4)
    }

    @Test("Outdent amount reaches only the previous stop when not aligned")
    func outdentPartialAlignment() {
        #expect(MarkdownTextEditing.outdentAmount(linePrefix: "  ") == 2)
        #expect(MarkdownTextEditing.outdentAmount(linePrefix: "      ") == 2)
    }

    @Test("Outdent does not apply when the line prefix has non-space characters")
    func outdentSkipsNonSpacePrefix() {
        #expect(MarkdownTextEditing.outdentAmount(linePrefix: "  x ") == nil)
        #expect(MarkdownTextEditing.outdentAmount(linePrefix: "") == nil)
    }

    // MARK: - Auto-pair brackets/quotes (issue #16)

    @Test("Typing an opener with no selection inserts the pair", arguments: [
        Character("("), Character("["), Character("{"), Character("<"),
    ])
    func insertsAsymmetricPair(opener: Character) throws {
        let decision = MarkdownTextEditing.pairDecision(for: opener, nextCharacter: nil, hasSelection: false)
        #expect(try decision == .insertPair(opening: opener, closing: #require(MarkdownTextEditing.pairs[opener])))
    }

    @Test("Typing a quote/backtick with no selection inserts the pair when context is safe")
    func insertsSymmetricPair() {
        let decision = MarkdownTextEditing.pairDecision(for: "\"", nextCharacter: " ", hasSelection: false)
        #expect(decision == .insertPair(opening: "\"", closing: "\""))
    }

    @Test("Typing a quote mid-word does not auto-pair")
    func doesNotPairMidWord() {
        let decision = MarkdownTextEditing.pairDecision(for: "'", nextCharacter: "s", hasSelection: false)
        #expect(decision == .insertPlain)
    }

    @Test("Typing a closing character that's already at the cursor skips over it")
    func skipsOverExistingCloser() {
        let decision = MarkdownTextEditing.pairDecision(for: ")", nextCharacter: ")", hasSelection: false)
        #expect(decision == .skipOver)
    }

    @Test("Typing a matching quote already at the cursor skips over it")
    func skipsOverExistingQuote() {
        let decision = MarkdownTextEditing.pairDecision(for: "\"", nextCharacter: "\"", hasSelection: false)
        #expect(decision == .skipOver)
    }

    @Test("Typing a bracket/quote with a selection wraps the selection")
    func wrapsSelectionWithBracket() {
        let decision = MarkdownTextEditing.pairDecision(for: "(", nextCharacter: nil, hasSelection: true)
        #expect(decision == .wrapSelection(opening: "(", closing: ")"))
    }

    @Test("Typing a markup character with a selection wraps the selection", arguments: [
        Character("*"), Character("_"), Character("~"), Character("="),
    ])
    func wrapsSelectionWithMarkup(marker: Character) {
        let decision = MarkdownTextEditing.pairDecision(for: marker, nextCharacter: nil, hasSelection: true)
        #expect(decision == .wrapSelection(opening: marker, closing: marker))
    }

    @Test("A non-pairing character with a selection inserts normally")
    func plainCharacterWithSelectionInsertsNormally() {
        let decision = MarkdownTextEditing.pairDecision(for: "x", nextCharacter: nil, hasSelection: true)
        #expect(decision == .insertPlain)
    }

    @Test("Backspace between an empty pair deletes both characters atomically")
    func atomicPairDeletion() {
        #expect(MarkdownTextEditing.isAtomicPairDeletion(before: "(", after: ")"))
        #expect(MarkdownTextEditing.isAtomicPairDeletion(before: "\"", after: "\""))
        #expect(!MarkdownTextEditing.isAtomicPairDeletion(before: "(", after: "x"))
        #expect(!MarkdownTextEditing.isAtomicPairDeletion(before: nil, after: ")"))
    }

    // MARK: - Smart Home key (issue #51)

    @Test("First Home press moves to the first non-whitespace character")
    func smartHomeFirstPress() {
        let line: Substring = "    hello"
        #expect(MarkdownTextEditing.smartHomeColumn(line: line, caretColumn: 9) == 4)
    }

    @Test("Home at the first non-whitespace character moves to true column 0")
    func smartHomeSecondPress() {
        let line: Substring = "    hello"
        #expect(MarkdownTextEditing.smartHomeColumn(line: line, caretColumn: 4) == 0)
    }

    @Test("Home on an all-whitespace line moves to column 0")
    func smartHomeAllWhitespaceLine() {
        let line: Substring = "    "
        #expect(MarkdownTextEditing.smartHomeColumn(line: line, caretColumn: 4) == 0)
    }

    @Test("Home on an unindented line moves to column 0")
    func smartHomeUnindentedLine() {
        let line: Substring = "hello"
        #expect(MarkdownTextEditing.smartHomeColumn(line: line, caretColumn: 3) == 0)
    }

    // MARK: - Limit editor width (issue #50)

    @Test("Width limit off leaves the inset unchanged regardless of view width")
    func widthLimitOffLeavesInsetUnchanged() {
        let inset = MarkdownTextEditing.widthLimitedHorizontalInset(
            viewWidth: 2000, baseInset: 15, isWidthLimited: false, maximumWidth: 800
        )
        #expect(inset == 15)
    }

    @Test("Width limit on but view narrower than the max leaves the inset unchanged")
    func widthLimitOnButNarrowLeavesInsetUnchanged() {
        let inset = MarkdownTextEditing.widthLimitedHorizontalInset(
            viewWidth: 700, baseInset: 15, isWidthLimited: true, maximumWidth: 800
        )
        #expect(inset == 15)
    }

    @Test("Width limit on and view wider than the max grows the inset by 45% of the excess")
    func widthLimitOnWiderGrowsInsetLeftBiased() {
        let inset = MarkdownTextEditing.widthLimitedHorizontalInset(
            viewWidth: 1800, baseInset: 15, isWidthLimited: true, maximumWidth: 800
        )
        #expect(inset == 15 + 1000 * 0.45)
    }

    // MARK: - List/blockquote continuation on Enter (issue #15)

    @Test("Enter at the end of a bullet list item continues the same marker")
    func continuesBulletList() {
        let action = MarkdownTextEditing.continuationAction(forLine: "- item one", autoIncrement: true)
        #expect(action == .continuePrefix("- "))
    }

    @Test("Enter at the end of an ordered list item increments the number when auto-increment is on")
    func continuesOrderedListWithIncrement() {
        let action = MarkdownTextEditing.continuationAction(forLine: "3. third", autoIncrement: true)
        #expect(action == .continuePrefix("4. "))
    }

    @Test("Enter at the end of an ordered list item repeats the number when auto-increment is off")
    func continuesOrderedListWithoutIncrement() {
        let action = MarkdownTextEditing.continuationAction(forLine: "3. third", autoIncrement: false)
        #expect(action == .continuePrefix("3. "))
    }

    @Test("Enter preserves indentation on a nested list item")
    func continuesNestedListPreservesIndent() {
        let action = MarkdownTextEditing.continuationAction(forLine: "  - nested", autoIncrement: true)
        #expect(action == .continuePrefix("  - "))
    }

    @Test("Enter at the end of a blockquote line continues the quote marker")
    func continuesBlockquote() {
        let action = MarkdownTextEditing.continuationAction(forLine: "> quoted text", autoIncrement: true)
        #expect(action == .continuePrefix("> "))
    }

    @Test("Enter on an empty list item terminates the list instead of continuing it")
    func emptyListItemTerminates() {
        let action = MarkdownTextEditing.continuationAction(forLine: "- ", autoIncrement: true)
        #expect(action == .terminateList)
    }

    @Test("Enter on an empty blockquote line terminates the quote")
    func emptyBlockquoteTerminates() {
        let action = MarkdownTextEditing.continuationAction(forLine: "> ", autoIncrement: true)
        #expect(action == .terminateList)
    }

    @Test("Enter on a plain paragraph line does nothing special")
    func plainLineDoesNothing() {
        let action = MarkdownTextEditing.continuationAction(forLine: "just a paragraph", autoIncrement: true)
        #expect(action == .none)
    }

    // MARK: - Selection restoration after a programmatic replacement

    @Test("Selection after an insertion lands right past the inserted text")
    func selectionAfterInsertionLandsPastInsertedText() {
        let selection = MarkdownTextEditing.selectionAfterReplacement(
            range: NSRange(location: 6, length: 0), replacementLength: 3
        )
        #expect(selection == NSRange(location: 9, length: 0))
    }

    @Test("Selection after a deletion collapses to the deletion's start")
    func selectionAfterDeletionCollapsesToStart() {
        let selection = MarkdownTextEditing.selectionAfterReplacement(
            range: NSRange(location: 0, length: 4), replacementLength: 0
        )
        #expect(selection == NSRange(location: 0, length: 0))
    }

    // MARK: - GFM task list continuation on Enter (issue #15 completeness)

    @Test("Enter at the end of an unchecked task list item continues with a fresh unchecked checkbox")
    func continuesTaskListWithFreshCheckbox() {
        let action = MarkdownTextEditing.continuationAction(forLine: "- [ ] todo", autoIncrement: true)
        #expect(action == .continuePrefix("- [ ] "))
    }

    @Test("Enter at the end of a checked task list item still continues with an unchecked checkbox")
    func continuesCheckedTaskListWithUncheckedCheckbox() {
        let action = MarkdownTextEditing.continuationAction(forLine: "- [x] done", autoIncrement: true)
        #expect(action == .continuePrefix("- [ ] "))
    }

    @Test("Enter on an empty task list item terminates the list instead of continuing it")
    func emptyTaskListItemTerminates() {
        let action = MarkdownTextEditing.continuationAction(forLine: "- [ ] ", autoIncrement: true)
        #expect(action == .terminateList)
    }

    @Test("Enter at the end of an ordered task list item increments the number and resets the checkbox")
    func continuesOrderedTaskListWithIncrement() {
        let action = MarkdownTextEditing.continuationAction(forLine: "1. [x] first", autoIncrement: true)
        #expect(action == .continuePrefix("2. [ ] "))
    }

    @Test("Enter preserves indentation on a nested task list item")
    func continuesNestedTaskListPreservesIndent() {
        let action = MarkdownTextEditing.continuationAction(forLine: "  - [ ] nested", autoIncrement: true)
        #expect(action == .continuePrefix("  - [ ] "))
    }
}
