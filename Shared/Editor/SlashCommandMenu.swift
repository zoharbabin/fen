import Foundation

/// A `/`-trigger match: the range to remove (the triggering `/` through the caret) and the
/// filter text typed after it, used to narrow `SlashCommandMenu.entries` (issue #1 rule 3.2).
public struct SlashCommandTriggerMatch: Equatable, Sendable {
    public let range: NSRange
    public let filterText: String
}

/// Pure, platform-independent slash-command menu logic (issue #1,
/// github.com/zoharbabin/fen/issues/1): trigger detection, the fixed block-type list, and
/// filtering. Kept separate from `MarkdownTextView`/`MarkdownTextView_iOS`'s Coordinator wiring,
/// mirroring `MarkdownTextEditing`'s existing pure-function pattern, so every rule is
/// unit-testable without constructing a real text view.
public enum SlashCommandMenu {
    /// One row of the menu: its display title and the `FormattingAction` selecting it applies.
    public struct Entry: Equatable, Sendable {
        public let title: String
        public let action: FormattingAction
    }

    /// The fixed, bounded 7-entry block-type list (issue #1 rule 4.1) -- always this exact set,
    /// never derived from document content, so filtering is bounded work regardless of document
    /// size.
    public static let entries: [Entry] = [
        Entry(title: "Heading", action: .heading1),
        Entry(title: "Table", action: .table),
        Entry(title: "Image", action: .image),
        Entry(title: "Quote", action: .blockquote),
        Entry(title: "Code Block", action: .codeBlock),
        Entry(title: "Horizontal Rule", action: .horizontalRule),
        Entry(title: "Diagram", action: .mermaidDiagram),
    ]

    /// Whether the caret at `cursorLocation` currently sits in an active slash-command trigger,
    /// and if so, the range to remove and the filter text to match against `entries`. `/` only
    /// triggers at the start of a line or immediately after whitespace (issue #1 rule 3.2) --
    /// typing it mid-word (a URL fragment like `http://`, or `and/or`) never opens the menu.
    /// Scoped to the caret's current line via `NSString.lineRange(for:)`, mirroring
    /// `MarkdownTextEditing.continuationAction`'s callers, never a full-document scan (rule 4.2).
    public static func triggerMatch(text: String, cursorLocation: Int) -> SlashCommandTriggerMatch? {
        let ns = text as NSString
        let length = ns.length
        guard cursorLocation >= 0, cursorLocation <= length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: cursorLocation, length: 0))

        var index = cursorLocation
        while index > lineRange.location {
            let currentCharacter = ns.substring(with: NSRange(location: index - 1, length: 1))
            if currentCharacter == "/" {
                let slashLocation = index - 1
                let atLineStart = slashLocation == lineRange.location
                let precedingIsWhitespace = !atLineStart &&
                    ns.substring(with: NSRange(location: slashLocation - 1, length: 1))
                    .first?.isWhitespace == true
                guard atLineStart || precedingIsWhitespace else { return nil }

                let filterText = ns.substring(
                    with: NSRange(location: slashLocation + 1, length: cursorLocation - (slashLocation + 1))
                )
                return SlashCommandTriggerMatch(
                    range: NSRange(location: slashLocation, length: cursorLocation - slashLocation),
                    filterText: filterText
                )
            }
            if currentCharacter.first?.isWhitespace == true {
                return nil
            }
            index -= 1
        }
        return nil
    }

    /// Case-insensitive substring match of `query` against each entry's title. An unmatched
    /// query returns an empty list rather than falling back to showing every entry (issue #1
    /// rule 3.3); an empty query (the menu just opened, nothing typed yet) shows every entry.
    public static func filteredEntries(query: String) -> [Entry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.title.range(of: query, options: [.caseInsensitive]) != nil }
    }
}
