import Foundation

/// How a diff line relates to the old and new text.
public enum DiffLineKind: String, Codable, Sendable {
    case context
    case added
    case removed
    /// Stands for skipped unchanged lines.
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

    public static func make(old: String, new: String, context: Int = 2, maxLines: Int = 400) -> LineDiff {
        let oldLines = split(old)
        let newLines = split(new)
        var removedAt = Set<Int>()
        var insertedAt = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case let .remove(offset, _, _): removedAt.insert(offset)
            case let .insert(offset, _, _): insertedAt.insert(offset)
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

    /// Keeps `context` lines around each change and folds the rest into one gap marker.
    private static func trim(_ all: [Line], context: Int, maxLines: Int) -> [Line] {
        var keep = Set<Int>()
        for index in all.indices where all[index].kind != .context {
            keep.formUnion(max(0, index - context) ... min(all.count - 1, index + context))
        }
        var lines: [Line] = []
        var skipping = false
        for (index, line) in all.enumerated() {
            if keep.contains(index) {
                skipping = false
                if lines.count < maxLines {
                    lines.append(line)
                }
            } else if !skipping {
                skipping = true
                lines.append(Line(kind: .gap, text: ""))
            }
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
            case .gap: "…"
            }
        }
        return rendered.joined(separator: "\n")
    }
}
