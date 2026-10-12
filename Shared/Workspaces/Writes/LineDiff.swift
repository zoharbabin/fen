import Foundation

/// How a diff line relates to the old and new text.
public enum DiffLineKind: String, Codable, Sendable {
    case context
    case added
    case removed
    /// Stands for skipped unchanged lines. With text, it says how many lines past the limit aren't shown.
    case gap
}

/// A line diff for the approval and activity views (issue #140). Uses the standard library's
/// `CollectionDifference`, with two lines of context around each change.
public struct LineDiff: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public var kind: DiffLineKind
        public var text: String
    }

    public var lines: [Line]
    public var added: Int
    public var removed: Int
    /// Lines in the old text, for the "share of the document changed" cap.
    public var oldLineCount: Int

    public var isEmpty: Bool {
        added == 0 && removed == 0
    }

    /// The larger of the share of old lines removed and the share of new lines added.
    public var changedFraction: Double {
        let newCount = max(oldLineCount - removed + added, 1)
        return max(Double(removed) / Double(max(oldLineCount, 1)), Double(added) / Double(newCount))
    }

    static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Above this many changed-region lines (old plus new), Fen skips the line-by-line compare,
    /// which grows with the square of the change, and shows the region as removed, then added.
    static let maxComparedLines = 4000

    public static func make(old: String, new: String, context: Int = 2, maxLines: Int = 400) -> LineDiff {
        let oldLines = split(old)
        let newLines = split(new)
        // Only the region between the common first and last lines can differ.
        let shorter = min(oldLines.count, newLines.count)
        var head = 0
        while head < shorter, oldLines[head] == newLines[head] {
            head += 1
        }
        var tail = 0
        while tail < shorter - head, oldLines[oldLines.count - 1 - tail] == newLines[newLines.count - 1 - tail] {
            tail += 1
        }
        let oldRegion = head ..< oldLines.count - tail
        let newRegion = head ..< newLines.count - tail
        var removedAt = Set<Int>()
        var insertedAt = Set<Int>()
        if oldRegion.count + newRegion.count > maxComparedLines {
            removedAt = Set(oldRegion)
            insertedAt = Set(newRegion)
        } else {
            for change in Array(newLines[newRegion]).difference(from: Array(oldLines[oldRegion])) {
                switch change {
                case let .remove(offset, _, _): removedAt.insert(head + offset)
                case let .insert(offset, _, _): insertedAt.insert(head + offset)
                }
            }
        }
        let all = interleave(oldLines, newLines, removedAt: removedAt, insertedAt: insertedAt)
        return LineDiff(
            lines: trim(all, context: context, maxLines: maxLines),
            added: insertedAt.count,
            removed: removedAt.count,
            oldLineCount: oldLines.count
        )
    }

    /// Walks both texts together into one ordered list.
    private static func interleave(
        _ oldLines: [String],
        _ newLines: [String],
        removedAt: Set<Int>,
        insertedAt: Set<Int>
    ) -> [Line] {
        var all: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedAt.contains(oldIndex) {
                all.append(Line(kind: .removed, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, insertedAt.contains(newIndex) {
                all.append(Line(kind: .added, text: newLines[newIndex]))
                newIndex += 1
            } else {
                all.append(Line(kind: .context, text: oldIndex < oldLines.count ? oldLines[oldIndex] : ""))
                oldIndex += 1
                newIndex += 1
            }
        }
        return all
    }

    /// Keeps `context` lines around each change and folds the rest into one gap marker. Past
    /// `maxLines`, a last gap marker says how many lines aren't shown.
    private static func trim(_ all: [Line], context: Int, maxLines: Int) -> [Line] {
        var keep = Set<Int>()
        for index in all.indices where all[index].kind != .context {
            keep.formUnion(max(0, index - context) ... min(all.count - 1, index + context))
        }
        var lines: [Line] = []
        var skipping = false
        var hidden = 0
        for (index, line) in all.enumerated() {
            if keep.contains(index) {
                skipping = false
                if lines.count < maxLines {
                    lines.append(line)
                } else {
                    hidden += 1
                }
            } else if !skipping {
                skipping = true
                if lines.count < maxLines {
                    lines.append(Line(kind: .gap, text: ""))
                }
            }
        }
        if hidden > 0 {
            lines.append(Line(
                kind: .gap,
                text: hidden == 1 ? "1 more line not shown" : "\(hidden) more lines not shown"
            ))
        }
        return lines
    }

    /// Plain text, one line per entry, for logs and tests.
    public var rendered: String {
        let rendered = lines.map { line in
            switch line.kind {
            case .context: "  " + line.text
            case .added: "+ " + line.text
            case .removed: "- " + line.text
            case .gap: line.text.isEmpty ? "…" : "… " + line.text
            }
        }
        return rendered.joined(separator: "\n")
    }
}
