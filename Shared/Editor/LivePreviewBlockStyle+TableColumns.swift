import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

extension LivePreviewBlockStyle {
    /// Lines up the columns of `table`, so the lines drawn at the pipes run straight whatever spacing the source
    /// has. Each cell grows by a `.kern` on its last character to the width of the widest cell in its column. The
    /// widths are read from the styled text, so hidden marks (`**`, links) don't count. The row with the caret
    /// shows its source and is left out. Call it after the table's lines are styled, between `beginEditing()` and
    /// `endEditing()`.
    static func alignTable(_ table: LivePreviewEditing.TableBlock, active: NSRange, storage: NSTextStorage) {
        guard let first = table.lines.first, let last = table.lines.last else { return }
        storage.removeAttribute(
            .kern,
            range: NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        )
        let text = storage.string as NSString
        var rows: [[NSRange]] = []
        for (index, line) in table.lines.enumerated()
            where index != 1 && NSIntersectionRange(line, active).length == 0 {
            rows.append(cells(of: line, in: text))
        }
        var widest: [CGFloat] = []
        let widths = rows.map { row in
            row.map { storage.attributedSubstring(from: $0).size().width }
        }
        for row in widths {
            for (column, width) in row.enumerated() {
                if column < widest.count {
                    widest[column] = max(widest[column], width)
                } else {
                    widest.append(width)
                }
            }
        }
        for (cells, row) in zip(rows, widths) {
            for (column, cell) in cells.enumerated() where widest[column] - row[column] >= 0.5 {
                storage.addAttribute(
                    .kern, value: widest[column] - row[column], range: NSRange(
                        location: NSMaxRange(cell) - 1,
                        length: 1
                    )
                )
            }
        }
    }

    /// The part of `line` before each pipe, from the pipe before it. A leading pipe starts the first cell, not an
    /// empty one. Text after the last pipe has no pipe to line up, so it isn't a cell.
    private static func cells(of line: NSRange, in text: NSString) -> [NSRange] {
        let pipes = LivePreviewEditing.tablePipes(line: text.substring(with: line), lineStart: line.location)
        var cells: [NSRange] = []
        var start = line.location
        for pipe in pipes {
            let isLeading = pipe.location == pipes.first?.location
                && text.substring(with: NSRange(location: line.location, length: pipe.location - line.location))
                .trimmingCharacters(in: .whitespaces).isEmpty
            if !isLeading, pipe.location > start {
                cells.append(NSRange(location: start, length: pipe.location - start))
            }
            start = pipe.location
        }
        return cells
    }
}
