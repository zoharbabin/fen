import Foundation

/// Numbers for ordered lists in Live Preview (issue #135, phase 4). Markdown numbers a list from its first item,
/// whatever the other items say, so `1. 1. 1.` reads 1, 2, 3.
public extension LivePreviewEditing {
    /// The number each ordered list item shows, for the items whose typed number differs from it. Keys are line
    /// starts. Lines in `fenced` and front matter are skipped, and a fence ends a list.
    static func listOrdinals(in text: String, excluding fenced: [NSRange], frontMatterEnd: Int) -> [Int: Int] {
        let ns = text as NSString
        var numbering = ListNumbering()
        var result: [Int: Int] = [:]
        var afterBlank = false
        var fence = 0
        var location = frontMatterEnd
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            while fence < fenced.count, NSMaxRange(fenced[fence]) <= lineRange.location {
                fence += 1
            }
            if fence < fenced.count, NSLocationInRange(lineRange.location, fenced[fence]) {
                numbering.endAll()
                continue
            }
            var content = lineRange
            while content.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(content) - 1)) {
                content.length -= 1
            }
            let line = ns.substring(with: content)
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                afterBlank = true
                continue
            }
            defer { afterBlank = false }
            guard let item = listItem(line: line, lineStart: lineRange.location) else {
                let indented = line.first == " " || line.first == "\t"
                // A line right under an item, with no blank line between, continues its paragraph.
                if !indented, afterBlank || line.hasPrefix("#") || line.hasPrefix(">") {
                    numbering.endAll()
                }
                continue
            }
            let indent = ns.substring(with: item.indent).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let delimiter = ns.character(at: NSMaxRange(item.marker) - 1)
            guard item.isOrdered else {
                numbering.bullet(indent: indent)
                continue
            }
            let digits = NSRange(location: item.marker.location, length: item.marker.length - 1)
            if let shown = numbering.ordered(
                indent: indent,
                delimiter: delimiter,
                typed: Int(ns.substring(with: digits)) ?? 0
            ) {
                result[lineRange.location] = shown
            }
        }
        return result
    }
}

/// The lists open at the current line, one per indent.
private struct ListNumbering {
    private struct Level {
        var indent: Int
        var isOrdered: Bool
        var delimiter: unichar
        var next: Int
    }

    private var levels: [Level] = []

    mutating func endAll() {
        levels.removeAll()
    }

    mutating func bullet(indent: Int) {
        replaceOrAppend(Level(indent: indent, isOrdered: false, delimiter: 0, next: 0))
    }

    /// The number the item shows when it isn't `typed`, or `nil` when it is.
    mutating func ordered(indent: Int, delimiter: unichar, typed: Int) -> Int? {
        while let top = levels.last, top.indent > indent {
            levels.removeLast()
        }
        if let top = levels.last, top.indent == indent, top.isOrdered, top.delimiter == delimiter {
            levels[levels.count - 1].next += 1
            return top.next == typed ? nil : top.next
        }
        replaceOrAppend(Level(indent: indent, isOrdered: true, delimiter: delimiter, next: typed + 1))
        return nil
    }

    private mutating func replaceOrAppend(_ level: Level) {
        while let top = levels.last, top.indent > level.indent {
            levels.removeLast()
        }
        if levels.last?.indent == level.indent {
            levels[levels.count - 1] = level
        } else {
            levels.append(level)
        }
    }
}
