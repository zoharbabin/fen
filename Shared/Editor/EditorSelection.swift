import Foundation

/// The text near the caret that Fen looks up related documents for (issue #8).
public struct EditorSelection: Equatable, Sendable {
    public enum Kind: Sendable {
        /// Text you selected.
        case selection
        /// The paragraph you are writing.
        case paragraph
    }

    public let kind: Kind
    public let text: String
    /// Where `text` sits in the document, in UTF-16 units. For a paragraph, an empty range at its end.
    public let range: NSRange

    static let minimumSelectionLength = 12
    static let minimumParagraphLength = 40
    static let maximumSelectionLength = 5000

    /// What to look up for the caret or selection `selected` in `document`, or `nil` when there is
    /// too little text. A paragraph counts only while you are `typing`.
    public static func make(in document: String, selected: NSRange, typing: Bool) -> EditorSelection? {
        let source = document as NSString
        guard selected.location != NSNotFound, NSMaxRange(selected) <= source.length else { return nil }
        if selected.length > 0 {
            guard selected.length <= maximumSelectionLength else { return nil }
            let text = source.substring(with: selected)
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumSelectionLength
            else { return nil }
            return EditorSelection(kind: .selection, text: text, range: selected)
        }
        guard typing else { return nil }
        let range = paragraphRange(in: source, around: selected.location)
        let text = source.substring(with: range)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumParagraphLength,
              !text.hasPrefix("#"), !text.hasPrefix("```") else { return nil }
        return EditorSelection(kind: .paragraph, text: text, range: NSRange(location: NSMaxRange(range), length: 0))
    }

    /// The lines around `location` up to the next blank line on each side, without the final newline.
    static func paragraphRange(in text: NSString, around location: Int) -> NSRange {
        func isBlank(_ line: NSRange) -> Bool {
            text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var start = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        if isBlank(start) {
            return NSRange(location: min(location, text.length), length: 0)
        }
        var end = start
        while start.location > 0 {
            let previous = text.lineRange(for: NSRange(location: start.location - 1, length: 0))
            if isBlank(previous) {
                break
            }
            start = previous
        }
        while NSMaxRange(end) < text.length {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(end), length: 0))
            if isBlank(next) {
                break
            }
            end = next
        }
        var range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        while range.length > 0,
              text.character(at: NSMaxRange(range) - 1) == 10 || text.character(at: NSMaxRange(range) - 1) == 13 {
            range.length -= 1
        }
        return range
    }

    /// The text under a heading, down to the next heading of the same or a higher level. `nil` when
    /// the heading isn't found or the section is nearly empty.
    public static func section(ofHeading title: String, level: Int, in document: String) -> String? {
        func plain(_ text: String) -> String {
            text.filter { !"*_` ".contains($0) }.lowercased()
        }
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
        var inFence = false
        var body: [Substring]?
        for line in lines {
            let isFence = line.hasPrefix("```") || line.hasPrefix("~~~")
            if isFence {
                inFence.toggle()
            }
            if inFence || isFence {
                body?.append(line)
                continue
            }
            let hashes = line.prefix { $0 == "#" }.count
            let isHeading = (1 ... 6).contains(hashes) && line.dropFirst(hashes).first == " "
            if let current = body {
                if isHeading, hashes <= level {
                    return finish(current)
                }
                body?.append(line)
            } else if isHeading, hashes == level,
                      plain(String(line.dropFirst(hashes)).trimmingCharacters(in: CharacterSet(charactersIn: "# "))) ==
                      plain(title) {
                body = []
            }
        }
        return body.flatMap(finish)
    }

    private static func finish(_ lines: [Substring]) -> String? {
        let text = String(lines.joined(separator: "\n").prefix(2000))
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumSelectionLength ? text : nil
    }
}

/// One edit for the editor to apply, so it lands in the undo stack like typing. The editor skips
/// it when `expected` is no longer at `range`.
public struct EditorInsertion: Equatable, Sendable {
    public let id = UUID()
    public let range: NSRange
    public let expected: String
    public let text: String

    public init(range: NSRange, expected: String, text: String) {
        self.range = range
        self.expected = expected
        self.text = text
    }

    /// Whether `document` still holds `expected` at `range`.
    public func applies(to document: String) -> Bool {
        let source = document as NSString
        return range.location != NSNotFound && NSMaxRange(range) <= source.length
            && source.substring(with: range) == expected
    }
}
