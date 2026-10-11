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

    // MARK: - Tables

    /// A GFM pipe table: a header line, a delimiter line (`|---|:-:|`), then body lines.
    struct TableBlock: Equatable {
        /// Each line without its line break, header first.
        public let lines: [NSRange]

        public var header: NSRange {
            lines[0]
        }

        public var delimiter: NSRange {
            lines[1]
        }
    }

    private static let tableDelimiterPattern = #"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#

    /// Where the cells of `line` are split: every `|` that isn't escaped as `\|`. Ranges are offset by `lineStart`.
    static func tablePipes(line: String, lineStart: Int) -> [NSRange] {
        let ns = line as NSString
        var pipes: [NSRange] = []
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 92 { // backslash: skips the next character
                index += 2
                continue
            }
            if character == 124 {
                pipes.append(NSRange(location: lineStart + index, length: 1))
            }
            index += 1
        }
        return pipes
    }

    /// The cells of a table line without the spaces around them, so a cell is the text a reader sees.
    /// A leading and a trailing pipe don't make empty cells.
    static func tableCells(line: String, lineStart: Int) -> [NSRange] {
        let ns = line as NSString
        let pipes = tablePipes(line: line, lineStart: 0)
        var edges = [-1] + pipes.map(\.location) + [ns.length]
        var cells: [NSRange] = []
        let isBlank = { (start: Int, end: Int) in
            ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces).isEmpty
        }
        if edges.count > 2, isBlank(0, edges[1]) {
            edges.removeFirst()
        }
        if edges.count > 2, isBlank(edges[edges.count - 2] + 1, ns.length) {
            edges.removeLast()
        }
        for index in 0 ..< edges.count - 1 {
            var start = edges[index] + 1
            var end = edges[index + 1]
            while start < end, [32, 9].contains(ns.character(at: start)) {
                start += 1
            }
            while end > start, [32, 9].contains(ns.character(at: end - 1)) {
                end -= 1
            }
            cells.append(NSRange(location: lineStart + start, length: end - start))
        }
        return cells
    }

    static func isTableDelimiter(line: String) -> Bool {
        line.contains("|") && line.range(of: tableDelimiterPattern, options: .regularExpression) != nil
    }

    /// Every table in `text` outside `fenced` ranges. A table needs a header with a `|`, a delimiter line with the
    /// same number of cells, and ends at the first line that is blank or has no `|`.
    static func tables(in text: String, excluding fenced: [NSRange]) -> [TableBlock] {
        let ns = text as NSString
        var lines: [(range: NSRange, text: String)] = []
        var location = 0
        while location < ns.length {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            guard full.length > 0 else { break }
            var content = full
            while content.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(content) - 1)) {
                content.length -= 1
            }
            lines.append((content, ns.substring(with: content)))
            location = NSMaxRange(full)
        }
        func isFenced(_ range: NSRange) -> Bool {
            fenced.contains { range.location >= $0.location && range.location < NSMaxRange($0) }
        }
        var blocks: [TableBlock] = []
        var index = 0
        while index + 1 < lines.count {
            let header = lines[index], delimiter = lines[index + 1]
            guard header.text.contains("|"), !isFenced(header.range), isTableDelimiter(line: delimiter.text),
                  tableCells(line: header.text, lineStart: 0).count
                  == tableCells(line: delimiter.text, lineStart: 0).count
            else {
                index += 1
                continue
            }
            var end = index + 2
            while end < lines.count, lines[end].text.contains("|"), !isFenced(lines[end].range) {
                end += 1
            }
            blocks.append(TableBlock(lines: lines[index ..< end].map(\.range)))
            index = end
        }
        return blocks
    }
}
