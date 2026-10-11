import Foundation

/// Block-level Live Preview detection for horizontal rules, lists, footnotes and front matter
/// (issue #135, phase 1). Pure functions on text, like the rest of `LivePreviewEditing`.
public extension LivePreviewEditing {
    /// A bullet or numbered list line, split into the parts the styler needs.
    struct ListItem: Equatable {
        /// The leading spaces and tabs.
        public let indent: NSRange
        /// The `-`, `*`, `+`, or `1.` and `1)` marker, without the space after it.
        public let marker: NSRange
        /// The marker and the spaces after it: the width a wrapped line hangs by.
        public let prefix: NSRange
        public let isOrdered: Bool
    }

    /// A `[^id]` reference or a `[^id]:` definition label.
    struct FootnoteSpan: Equatable {
        public let range: NSRange
        public let isDefinition: Bool
    }

    private static let rulePattern = #"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#
    private static let listPattern = #"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)\S"#
    private static let footnotePattern = #"\[\^[^\]\s]+\]"#

    /// Whether `line` is a thematic break (`---`, `***`, `___`, with optional spaces between).
    /// A run of dashes right under a line of text is a setext heading underline, not a rule.
    static func isHorizontalRule(line: String, previousLine: String?) -> Bool {
        guard line.range(of: rulePattern, options: .regularExpression) != nil else { return false }
        let underlinesText = line.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "-" }
            && previousLine.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } == true
        return !underlinesText
    }

    /// The list parts of `line`, or `nil` when it isn't a list item. A task item (`- [ ] `) is a list
    /// item too. Ranges are offset by `lineStart`.
    static func listItem(line: String, lineStart: Int) -> ListItem? {
        guard let regex = try? NSRegularExpression(pattern: listPattern) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func shifted(_ range: NSRange) -> NSRange {
            NSRange(location: lineStart + range.location, length: range.length)
        }
        let indent = match.range(at: 1), marker = match.range(at: 2), gap = match.range(at: 3)
        return ListItem(
            indent: shifted(indent),
            marker: shifted(marker),
            prefix: shifted(NSRange(location: marker.location, length: marker.length + gap.length)),
            isOrdered: ns.character(at: marker.location) >= 48 && ns.character(at: marker.location) <= 57
        )
    }

    /// Every `[^id]` in `line`. One at the very start of a line followed by `:` is a definition label.
    static func footnoteSpans(in line: String, lineStart: Int) -> [FootnoteSpan] {
        guard let regex = try? NSRegularExpression(pattern: footnotePattern) else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { match in
            let end = match.range.location + match.range.length
            let isDefinition = match.range.location == 0 && end < ns.length && ns.character(at: end) == 58
            return FootnoteSpan(
                range: NSRange(location: lineStart + match.range.location, length: match.range.length),
                isDefinition: isDefinition
            )
        }
    }

    /// The front matter block: `---` on the first line to the next `---` line, both included.
    /// `nil` when the document has none, or the block never closes.
    static func frontMatterRange(text: String) -> NSRange? {
        let ns = text as NSString
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        var location = ns.lineRange(for: NSRange(location: 0, length: 0)).length
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                return NSRange(location: 0, length: NSMaxRange(line))
            }
            location = NSMaxRange(line)
        }
        return nil
    }
}
