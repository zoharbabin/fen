import Foundation

/// A piece of one document, small enough to embed and to show as a search result.
struct DocumentChunk: Equatable, Sendable {
    /// The heading trail, for example `Setup > Install`. Empty before the first heading.
    let heading: String
    /// 1-based line in the file where the chunk starts.
    let startLine: Int
    let text: String
    /// `false` for front matter. Its keys and punctuation would only add noise to the vectors.
    let embeddable: Bool
}

struct DocumentLink: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// A Markdown link to a file. `target` is the workspace-relative path.
        case path
        /// A `[[wiki link]]`. `target` is the lowercased name or path without extension.
        case wiki
    }

    let kind: Kind
    let target: String
}

struct ParsedDocument: Equatable, Sendable {
    let title: String
    let chunks: [DocumentChunk]
    let links: [DocumentLink]
}

/// Splits Markdown into heading-sized chunks and pulls out its links (issue #35). Pure text in,
/// values out: no file or index access.
enum MarkdownChunker {
    static let maxChunkCharacters = 1200
    /// A guard for huge files. Later sections are not indexed past this.
    static let maxChunks = 2000
    private static let maxFrontMatterCharacters = 600

    private static let markdownLink = try? NSRegularExpression(pattern: #"\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)
    private static let wikiLink = try? NSRegularExpression(pattern: #"\[\[([^\]\|#]+)(?:[#\|][^\]]*)?\]\]"#)

    static func parse(_ text: String, path: String) -> ParsedDocument {
        // "\r\n" is one Character in Swift, so split on both forms.
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map(String.init)
        var chunks: [DocumentChunk] = []
        var frontMatterTitle: String?
        var bodyStart = 0

        if let end = frontMatterEnd(lines) {
            let block = lines[1 ..< end]
            frontMatterTitle = block.compactMap(titleValue).first
            let joined = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                chunks.append(DocumentChunk(
                    heading: "Front matter",
                    startLine: 1,
                    text: String(joined.prefix(maxFrontMatterCharacters)),
                    embeddable: false
                ))
            }
            bodyStart = end + 1
        }
        lines = Array(lines.dropFirst(bodyStart))

        var firstHeading: String?
        var links: [DocumentLink] = []
        var stack: [(level: Int, text: String)] = []
        var section: [String] = []
        var sectionStart = bodyStart + 1
        var fence: (marker: Character, count: Int)?

        func flush() {
            let lines = section
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            section = []
            guard !body.isEmpty else { return }
            let trail = stack.map(\.text).joined(separator: " > ")
            var cursor = 0
            for piece in split(body, limit: maxChunkCharacters) where chunks.count < maxChunks {
                cursor = lineIndex(of: piece, in: lines, from: cursor)
                chunks.append(DocumentChunk(
                    heading: trail, startLine: sectionStart + cursor, text: piece, embeddable: true
                ))
            }
        }

        for (offset, line) in lines.enumerated() {
            let lineNumber = bodyStart + offset + 1
            if let open = fence {
                section.append(line)
                if closesFence(line, open) {
                    fence = nil
                }
                continue
            }
            if let opened = opensFence(line) {
                fence = opened
                if section.isEmpty {
                    sectionStart = lineNumber
                }
                section.append(line)
                continue
            }
            if let heading = atxHeading(line) {
                flush()
                while let top = stack.last, top.level >= heading.level {
                    stack.removeLast()
                }
                stack.append(heading)
                firstHeading = firstHeading ?? (heading.level == 1 ? heading.text : nil)
                sectionStart = lineNumber
                continue
            }
            if section.isEmpty {
                sectionStart = lineNumber
            }
            section.append(line)
            links += extractLinks(from: line, documentPath: path)
        }
        flush()

        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return ParsedDocument(title: frontMatterTitle ?? firstHeading ?? fallback, chunks: chunks, links: links)
    }

    // MARK: - Links

    static func extractLinks(from line: String, documentPath: String) -> [DocumentLink] {
        var found: [DocumentLink] = []
        let range = NSRange(line.startIndex..., in: line)
        markdownLink?.enumerateMatches(in: line, range: range) { match, _, _ in
            if let match, let target = Range(match.range(at: 1), in: line),
               let resolved = resolve(String(line[target]), from: documentPath) {
                found.append(DocumentLink(kind: .path, target: resolved))
            }
        }
        wikiLink?.enumerateMatches(in: line, range: range) { match, _, _ in
            if let match, let name = Range(match.range(at: 1), in: line) {
                let key = wikiKey(String(line[name]))
                if !key.isEmpty {
                    found.append(DocumentLink(kind: .wiki, target: key))
                }
            }
        }
        return found
    }

    /// The workspace-relative path a Markdown link points to, or `nil` for web links, anchors,
    /// and links that leave the workspace.
    static func resolve(_ target: String, from documentPath: String) -> String? {
        var value = target.removingPercentEncoding ?? target
        if let cut = value.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            value = String(value[..<cut])
        }
        guard !value.isEmpty, !value.contains(":") else { return nil }
        var parts: [Substring] = if value.hasPrefix("/") {
            []
        } else {
            documentPath.split(separator: "/").dropLast()
        }
        for part in value.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// The key a wiki link is matched by: lowercased, no extension, trimmed.
    static func wikiKey(_ name: String) -> String {
        var key = name.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in [".md", ".markdown", ".mdx", ".txt"] where key.hasSuffix(suffix) {
            key = String(key.dropLast(suffix.count))
        }
        return key
    }

    // MARK: - Lines

    private static func frontMatterEnd(_ lines: [String]) -> Int? {
        guard lines.first == "---" else { return nil }
        return lines.dropFirst().firstIndex { $0 == "---" || $0 == "..." }
    }

    private static func titleValue(_ line: String) -> String? {
        guard line.hasPrefix("title:") else { return nil }
        let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let unquoted = value.count >= 2 && (value.first == "\"" || value.first == "'") && value.last == value.first
            ? String(value.dropFirst().dropLast()) : value
        return unquoted.isEmpty ? nil : unquoted
    }

    private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3 else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func opensFence(_ line: String) -> (marker: Character, count: Int)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }
        let count = trimmed.prefix(while: { $0 == marker }).count
        return count >= 3 ? (marker, count) : nil
    }

    private static func closesFence(_ line: String, _ open: (marker: Character, count: Int)) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        let count = trimmed.prefix(while: { $0 == open.marker }).count
        return count >= open.count && trimmed.dropFirst(count).allSatisfy { $0 == " " }
    }

    // MARK: - Splitting

    /// The index in `lines`, at or after `start`, of the line a chunk's text begins on. Leading blank
    /// lines of a section are not part of its chunks, so a citation must not point at them.
    private static func lineIndex(of piece: String, in lines: [String], from start: Int) -> Int {
        let first = piece.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        for index in start ..< lines.count where lines[index].contains(first) && !first.isEmpty {
            return index
        }
        return start
    }

    /// Breaks `text` at blank lines, then at spaces, so no piece is longer than `limit`.
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var pieces: [String] = []
        var current = ""
        func add(_ part: String) {
            if current.isEmpty {
                current = part
            } else if current.count + 2 + part.count <= limit {
                current += "\n\n" + part
            } else {
                pieces.append(current)
                current = part
            }
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            let part = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty {
                continue
            }
            for fragment in hardSplit(part, limit: limit) {
                add(fragment)
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    private static func hardSplit(_ text: String, limit: Int) -> [String] {
        var rest = Substring(text)
        var out: [String] = []
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? window.endIndex
            let end = cut == window.startIndex ? window.endIndex : cut
            out.append(String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[end...].drop(while: { $0 == " " || $0 == "\n" })
        }
        if !rest.isEmpty {
            out.append(String(rest))
        }
        return out.filter { !$0.isEmpty }
    }
}
