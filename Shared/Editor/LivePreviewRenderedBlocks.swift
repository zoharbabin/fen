import Foundation

/// A block Live Preview shows as a picture of its rendered result: a Mermaid diagram, a map, or `$$` math (issue
/// #135, phase 3). `range` covers whole lines, line break included. `inlineMath` is the kind of picture only: a
/// formula inside a line is found as a span, not as a block.
struct RenderedBlock: Equatable {
    enum Kind: String, CaseIterable {
        case mermaid
        case math
        case map
        case inlineMath
    }

    var kind: Kind
    var range: NSRange
    /// The block's lines as written, without the final line break. This is what the web view renders.
    var source: String
}

extension LivePreviewEditing {
    /// The longest `$$` block Fen tries to match. A lone `$$` in prose shouldn't swallow the rest of the note.
    static let maxMathBlockLines = 40

    /// Blocks in `text` of the wanted `kinds`. Fences are matched by their info string (`mermaid`, `geojson`,
    /// `topojson`). A fence that never closes is not a block.
    static func renderedBlocks(in text: String, fenced: [NSRange], kinds: Set<RenderedBlock.Kind>) -> [RenderedBlock] {
        guard !kinds.isEmpty else { return [] }
        let ns = text as NSString
        var blocks: [RenderedBlock] = []
        for range in fenced {
            guard let kind = fenceKind(of: range, in: ns), kinds.contains(kind), isClosed(range, in: ns) else {
                continue
            }
            blocks.append(RenderedBlock(kind: kind, range: range, source: trimmedSource(range, in: ns)))
        }
        if kinds.contains(.math) {
            blocks += mathBlocks(in: ns, fenced: fenced, from: frontMatterRange(text: text).map { NSMaxRange($0) } ?? 0)
        }
        return blocks.sorted { $0.range.location < $1.range.location }
    }

    private static func fenceKind(of range: NSRange, in ns: NSString) -> RenderedBlock.Kind? {
        let opening = ns.substring(with: ns.lineRange(for: NSRange(location: range.location, length: 0)))
        let fence = opening.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "`" || $0 == "~" }
        let info = fence.trimmingCharacters(in: .whitespaces).split(separator: " ").first?.lowercased()
        switch info {
        case "mermaid": return .mermaid
        case "geojson", "topojson": return .map
        default: return nil
        }
    }

    private static func isClosed(_ range: NSRange, in ns: NSString) -> Bool {
        let last = ns.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
        guard last.location > range.location else { return false }
        let line = ns.substring(with: last).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private static func trimmedSource(_ range: NSRange, in ns: NSString) -> String {
        ns.substring(with: range).trimmingCharacters(in: .newlines)
    }

    /// `$$ x $$` on one line, or a `$$` line, some lines, and a line that ends with `$$`. A blank line ends the
    /// search, and so does a fence.
    private static func mathBlocks(in ns: NSString, fenced: [NSRange], from start: Int) -> [RenderedBlock] {
        var blocks: [RenderedBlock] = []
        var location = start
        while location < ns.length {
            // Jump to the next `$$`, so a long note without math costs one search and not a look at every line.
            let hit = ns.range(of: "$$", options: [], range: NSRange(location: location, length: ns.length - location))
            guard hit.location != NSNotFound else { break }
            let line = ns.lineRange(for: NSRange(location: hit.location, length: 0))
            guard line.length > 0 else { break }
            location = line.location
            let next = NSMaxRange(line)
            if let fence = fenced.first(where: { location >= $0.location && location < NSMaxRange($0) }) {
                location = NSMaxRange(fence)
                continue
            }
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("$$") else {
                location = next
                continue
            }
            if trimmed.count >= 5, trimmed.hasSuffix("$$") {
                blocks.append(block(line, in: ns))
                location = next
                continue
            }
            guard let end = closingMathLine(after: line, in: ns, fenced: fenced) else {
                location = next
                continue
            }
            let range = NSRange(location: line.location, length: NSMaxRange(end) - line.location)
            blocks.append(block(range, in: ns))
            location = NSMaxRange(range)
        }
        return blocks
    }

    private static func block(_ range: NSRange, in ns: NSString) -> RenderedBlock {
        RenderedBlock(kind: .math, range: range, source: trimmedSource(range, in: ns))
    }

    private static func closingMathLine(after opening: NSRange, in ns: NSString, fenced: [NSRange]) -> NSRange? {
        var location = NSMaxRange(opening)
        for _ in 0 ..< maxMathBlockLines where location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            guard line.length > 0, !fenced.contains(where: { NSLocationInRange(line.location, $0) }) else { return nil }
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return nil
            }
            if trimmed.hasSuffix("$$") {
                return line
            }
            location = NSMaxRange(line)
        }
        return nil
    }
}
