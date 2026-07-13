import Foundation

/// Pure, platform-independent text-editing logic for the Markdown editor's Tab/auto-pair/smart
/// Home/list-continuation behaviors (see issues #15, #16, #17, #51). Kept separate from
/// `MarkdownNSTextView`/iOS's `UITextView` wiring so every rule is unit-testable without
/// constructing a real text view.
public enum MarkdownTextEditing {
    public static let tabStop = 4

    // MARK: - Tabs-to-spaces (issue #17)

    /// Spaces to insert for a Tab keypress at `column` (0-based), rounding up to the next
    /// `tabStop`-column stop rather than always inserting a fixed count.
    public static func tabInsertion(atColumn column: Int) -> String {
        let toNextStop = tabStop - (column % tabStop)
        return String(repeating: " ", count: toNextStop)
    }

    /// Number of trailing spaces a Backspace should remove to outdent to the previous
    /// `tabStop`-column stop, or `nil` if outdenting doesn't apply (the text immediately before
    /// the cursor on this line isn't all spaces, or there's nothing to remove).
    public static func outdentAmount(linePrefix: String) -> Int? {
        guard !linePrefix.isEmpty, linePrefix.allSatisfy({ $0 == " " }) else { return nil }
        let column = linePrefix.count
        let previousStop = ((column - 1) / tabStop) * tabStop
        return column - previousStop
    }

    // MARK: - Auto-pair brackets/quotes (issue #16)

    /// Opening characters that auto-pair with a closing counterpart, and their closers.
    public static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "<": ">", "'": "'", "\"": "\"", "`": "`",
    ]

    /// Characters that wrap a non-empty selection when typed, beyond the bracket/quote pairs
    /// above (Markdown emphasis/strike/highlight markers).
    public static let wrappingMarkupCharacters: Set<Character> = ["*", "_", "~", "="]

    /// Whether `character` is a "surrounding" character that makes it safe to auto-insert a
    /// closing pair -- whitespace, punctuation, or none (end of text) -- so typing `(` mid-word
    /// (e.g. "wor(d") doesn't insert a stray closer no one asked for.
    public static func isPairableContext(nextCharacter: Character?) -> Bool {
        guard let nextCharacter else { return true }
        return nextCharacter.isWhitespace || nextCharacter.isPunctuation
    }

    public enum PairDecision: Equatable {
        /// Insert `opening` immediately followed by its closer, caret between them.
        case insertPair(opening: Character, closing: Character)
        /// The typed character matches the character already at the cursor -- skip over it
        /// instead of inserting a duplicate.
        case skipOver
        /// Wrap the current (non-empty) selection in `opening`/`closing`.
        case wrapSelection(opening: Character, closing: Character)
        /// No special handling -- insert the typed character normally.
        case insertPlain
    }

    /// Decides how a just-typed `character` should be handled given the character currently at
    /// the cursor (`nextCharacter`, `nil` at end of text) and whether there's a non-empty
    /// selection.
    public static func pairDecision(
        for character: Character, nextCharacter: Character?, hasSelection: Bool
    ) -> PairDecision {
        if hasSelection {
            if let closing = pairs[character] {
                return .wrapSelection(opening: character, closing: closing)
            }
            if wrappingMarkupCharacters.contains(character) {
                return .wrapSelection(opening: character, closing: character)
            }
            return .insertPlain
        }

        // Skip over a closing character (bracket, or symmetric quote/backtick) already sitting
        // at the cursor, instead of inserting a duplicate.
        if pairs.values.contains(character), nextCharacter == character {
            return .skipOver
        }

        if let closing = pairs[character] {
            guard isPairableContext(nextCharacter: nextCharacter) else { return .insertPlain }
            return .insertPair(opening: character, closing: closing)
        }

        return .insertPlain
    }

    /// Whether a Backspace with the cursor sitting between `before` and `after` should delete
    /// both characters atomically (an empty pair like `()` or `""`) instead of just `before`.
    public static func isAtomicPairDeletion(before: Character?, after: Character?) -> Bool {
        guard let before, let after else { return false }
        return pairs[before] == after
    }

    // MARK: - Smart Home key (issue #51)

    /// The 0-based column (within `line`) Home should move the caret to: the first
    /// non-whitespace character on the first press, or true column 0 if the caret is already
    /// there (or the line is all whitespace).
    public static func smartHomeColumn(line: Substring, caretColumn: Int) -> Int {
        let firstNonWhitespace = line.firstIndex { !$0.isWhitespace }
            .map { line.distance(from: line.startIndex, to: $0) } ?? 0
        return caretColumn > firstNonWhitespace ? firstNonWhitespace : 0
    }

    // MARK: - Limit editor width (issue #50)

    /// Ported from MacDown's `-adjustEditorInsets`: when the view is wider than
    /// `maximumWidth`, grows the horizontal `textContainerInset` component by 45% of the excess
    /// width on each side (not 50%, "because things in an editor tend to shift left" --
    /// MacDown's own comment) rather than clamping to a fixed value, so the text column lands
    /// slightly left-of-center instead of perfectly centered. Below `maximumWidth`, or when
    /// width-limiting is off, falls back to the plain `baseInset` the Layout section's slider
    /// already controls. Callers must recompute this on every width change and on initial load,
    /// not only when the preference is toggled -- MacDown's own issues #288 (margin-only resize
    /// bug) and #236 (not applied on load) are exactly the regressions that skipping either call
    /// would reintroduce.
    public static func widthLimitedHorizontalInset(
        viewWidth: CGFloat, baseInset: CGFloat, isWidthLimited: Bool, maximumWidth: CGFloat
    ) -> CGFloat {
        guard isWidthLimited else { return baseInset }
        let excess = viewWidth - maximumWidth
        guard excess > 0 else { return baseInset }
        return baseInset + excess * 0.45
    }

    // MARK: - List/blockquote continuation on Enter (issue #15)

    public enum ContinuationAction: Equatable {
        /// Insert a newline followed by `prefix` (the continued list marker/blockquote quote).
        case continuePrefix(String)
        /// The current line's prefix-only content (an empty list item/blockquote line) should be
        /// cleared instead of continued -- pressing Enter on an empty item ends the list.
        case terminateList
        /// Not a list or blockquote line -- handle Enter normally.
        case none
    }

    private static let unorderedListPattern = #"^(\s*)([-*+])(\s+)(\[[ xX]\]\s+)?(.*)$"#
    private static let orderedListPattern = #"^(\s*)(\d+)([.)])(\s+)(\[[ xX]\]\s+)?(.*)$"#
    private static let blockquotePattern = #"^(\s*)(>+)(\s?)(.*)$"#

    /// Decides what Enter should do given the full text of the line the caret is on (the caret
    /// must be at the end of that line -- callers should fall back to `.none` otherwise, matching
    /// MacDown's original behavior of only continuing at end-of-line).
    public static func continuationAction(forLine line: String, autoIncrement: Bool) -> ContinuationAction {
        if let match = firstMatch(of: orderedListPattern, in: line) {
            let indent = match[1], number = match[2], separator = match[3], checkbox = match[5], rest = match[6]
            if rest.isEmpty {
                return .terminateList
            }
            let nextNumberText = autoIncrement ? String((Int(number) ?? 0) + 1) : number
            // A task list item always continues with a fresh unchecked box, regardless of
            // whether the item being continued from was checked.
            let continuedCheckbox = checkbox.isEmpty ? "" : "[ ] "
            return .continuePrefix("\(indent)\(nextNumberText)\(separator) \(continuedCheckbox)")
        }
        if let match = firstMatch(of: unorderedListPattern, in: line) {
            let indent = match[1], marker = match[2], checkbox = match[4], rest = match[5]
            if rest.isEmpty {
                return .terminateList
            }
            let continuedCheckbox = checkbox.isEmpty ? "" : "[ ] "
            return .continuePrefix("\(indent)\(marker) \(continuedCheckbox)")
        }
        if let match = firstMatch(of: blockquotePattern, in: line) {
            let indent = match[1], quote = match[2], rest = match[4]
            if rest.isEmpty {
                return .terminateList
            }
            return .continuePrefix("\(indent)\(quote) ")
        }
        return .none
    }

    /// Runs `pattern` against `line` and returns each capture group's substring (index 0 is the
    /// whole match), or `nil` if it doesn't match.
    private static func firstMatch(of pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0 ..< match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return "" }
            return ns.substring(with: range)
        }
    }
}
