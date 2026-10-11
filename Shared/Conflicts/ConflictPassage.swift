import Foundation

/// A paragraph or list item of a note (issue #94). A conflict flag tracks its passages by the hash
/// of their text, not by line number, so a flag survives edits above or below.
struct ConflictPassage: Codable, Sendable, Equatable {
    /// 1-based line in the file where the passage starts.
    var startLine: Int
    var text: String
    var hash: String

    /// Passages shorter than this are headings, labels or fragments. They hold no claim worth checking.
    static let minimumCharacters = 25

    init(startLine: Int, text: String) {
        self.startLine = startLine
        self.text = text
        hash = Self.hash(of: text)
    }

    /// SHA-256 of the text with runs of whitespace collapsed, so re-wrapping a line doesn't change it.
    static func hash(of text: String) -> String {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return ContentHash.of(Data(normalized.utf8))
    }

    /// The first 12 characters of `hash`, enough to tell passages of one file apart.
    var shortHash: String {
        String(hash.prefix(12))
    }

    /// The passages of a note, in order. Skips front matter, fenced code, headings and fragments.
    /// Each paragraph and each top-level list item is one passage.
    static func split(_ text: String) -> [ConflictPassage] {
        var passages: [ConflictPassage] = []
        var block: [String] = []
        var blockStart = 0
        var inFence = false

        func flush() {
            defer { block = [] }
            let joined = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let isHeading = block.allSatisfy { $0.hasPrefix("#") }
            guard joined.count >= minimumCharacters, !isHeading else { return }
            passages.append(ConflictPassage(startLine: blockStart, text: joined))
        }

        let lines = text.components(separatedBy: "\n")
        var index = frontMatterEnd(lines)
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                inFence.toggle()
                continue
            }
            if inFence {
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if isListItemStart(line) || line.hasPrefix("#") {
                flush()
            }
            if !block.isEmpty, !line.hasPrefix("#"), block.allSatisfy({ $0.hasPrefix("#") }) {
                flush()
            }
            if block.isEmpty {
                blockStart = index
            }
            block.append(line)
        }
        flush()
        return passages
    }

    /// The passage in `text` whose hash is `hash`, if the text is still there.
    static func find(hash: String, in text: String) -> ConflictPassage? {
        split(text).first { $0.hash == hash }
    }

    /// Index of the first line after a leading `---` front matter block, or 0.
    private static func frontMatterEnd(_ lines: [String]) -> Int {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return 0 }
        for index in 1 ..< lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return index + 1
        }
        return 0
    }

    /// A list item at the left margin: `-`, `*`, `+` or `1.` followed by a space.
    private static func isListItemStart(_ line: String) -> Bool {
        guard let first = line.first, !first.isWhitespace else { return false }
        if "-*+".contains(first) {
            return line.dropFirst().first == " "
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 4 else { return false }
        let rest = line.dropFirst(digits.count)
        return (rest.first == "." || rest.first == ")") && rest.dropFirst().first == " "
    }
}
