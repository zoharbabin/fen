import Foundation

public extension Notification.Name {
    /// Posted with a `FormattingAction.identifier` string as `object` by every toolbar button
    /// and menu command; observed by each platform's `MarkdownTextView.Coordinator`.
    static let insertMarkdownFormatting = Notification.Name("insertMarkdownFormatting")
}

/// The set of Markdown formatting actions the toolbar and menu commands can apply.
/// See issue #13 (github.com/zoharbabin/fen/issues/13) for the full behavioral spec.
public enum FormattingAction: CaseIterable, Equatable, Hashable, Sendable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case heading1
    case heading2
    case heading3
    case bulletList
    case numberedList
    case taskItem
    case blockquote
    case link
    case image
    case horizontalRule
    case codeBlock
    case table

    /// The `.insertMarkdownFormatting` notification's `object` payload for this action --
    /// the wire format both the posting menu commands/toolbar buttons and the observing
    /// Coordinators agree on.
    public var identifier: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .inlineCode: "code"
        case .heading1: "h1"
        case .heading2: "h2"
        case .heading3: "h3"
        case .bulletList: "bulletList"
        case .numberedList: "numberedList"
        case .taskItem: "taskItem"
        case .blockquote: "blockquote"
        case .link: "link"
        case .image: "image"
        case .horizontalRule: "horizontalRule"
        case .codeBlock: "codeBlock"
        case .table: "table"
        }
    }

    public init?(identifier: String) {
        guard let match = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = match
    }

    /// Toolbar button label, SF Symbol, and accessibility identifier -- one source of truth
    /// so `SplitEditorView.toolbarContent` doesn't hand-roll a button per action.
    public var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Inline Code"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulletList: "Bullet List"
        case .numberedList: "Numbered List"
        case .taskItem: "Task Item"
        case .blockquote: "Blockquote"
        case .link: "Link"
        case .image: "Image"
        case .horizontalRule: "Horizontal Rule"
        case .codeBlock: "Code Block"
        case .table: "Table"
        }
    }

    public var systemImage: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .heading1: "1.square"
        case .heading2: "2.square"
        case .heading3: "3.square"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .taskItem: "checklist"
        case .blockquote: "text.quote"
        case .link: "link"
        case .image: "photo"
        case .horizontalRule: "minus"
        case .codeBlock: "curlybraces"
        case .table: "tablecells"
        }
    }

    /// `SplitEditorView.toolbarContent`/`FormattingToolbarUITests` accessibility identifier,
    /// e.g. `FormatBoldButton`, `FormatTableButton`.
    public var accessibilityIdentifier: String {
        "Format\(title.replacingOccurrences(of: " ", with: ""))Button"
    }
}

/// Pure text-transform for every `FormattingAction`. Takes a document's full text and the
/// caller's current selection, and returns the new text plus where the selection should land
/// afterward -- no live text view, no shared/module-level state (issue #13, rule 1.1), so both
/// platforms' Coordinators can call it directly with their own selection-type conversion.
public enum MarkdownFormatting {
    public static func apply(
        _ action: FormattingAction, to text: String, selection: NSRange
    ) -> (text: String, selection: NSRange) {
        switch action {
        case .bold:
            applyWrap(marker: "**", placeholder: "bold text", text: text, selection: selection)
        case .italic:
            applyWrap(marker: "*", placeholder: "italic text", text: text, selection: selection)
        case .strikethrough:
            applyWrap(marker: "~~", placeholder: "strikethrough text", text: text, selection: selection)
        case .inlineCode:
            applyWrap(marker: "`", placeholder: "code", text: text, selection: selection)
        case .heading1:
            applyHeading(level: 1, text: text, selection: selection)
        case .heading2:
            applyHeading(level: 2, text: text, selection: selection)
        case .heading3:
            applyHeading(level: 3, text: text, selection: selection)
        case .bulletList:
            applyLinePrefix(prefix: "- ", text: text, selection: selection)
        case .blockquote:
            applyLinePrefix(prefix: "> ", text: text, selection: selection)
        case .numberedList:
            applyNumberedList(text: text, selection: selection)
        case .taskItem:
            applyTaskItem(text: text, selection: selection)
        case .link:
            applyLink(isImage: false, text: text, selection: selection)
        case .image:
            applyLink(isImage: true, text: text, selection: selection)
        case .horizontalRule:
            applyHorizontalRule(text: text, selection: selection)
        case .codeBlock:
            applyCodeBlock(text: text, selection: selection)
        case .table:
            applyTable(text: text, selection: selection)
        }
    }

    // MARK: - Wrap/toggle (bold, italic, strikethrough, inline code)

    private static func applyWrap(
        marker: String, placeholder: String, text: String, selection: NSRange
    ) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let markerLength = (marker as NSString).length
        let bounded = boundedRange(selection, in: ns)

        if bounded.length == 0 {
            let replacement = marker + placeholder + marker
            let newText = ns.replacingCharacters(in: bounded, with: replacement)
            let newSelection = NSRange(
                location: bounded.location + markerLength,
                length: (placeholder as NSString).length
            )
            return (newText, newSelection)
        }

        let selectedText = ns.substring(with: bounded)
        if selectedText.hasPrefix(marker), selectedText.hasSuffix(marker),
           (selectedText as NSString).length >= markerLength * 2 {
            let inner = String(selectedText.dropFirst(marker.count).dropLast(marker.count))
            let newText = ns.replacingCharacters(in: bounded, with: inner)
            return (newText, NSRange(location: bounded.location, length: (inner as NSString).length))
        }

        let beforeRange = NSRange(location: bounded.location - markerLength, length: markerLength)
        let afterRange = NSRange(location: bounded.location + bounded.length, length: markerLength)
        if beforeRange.location >= 0, afterRange.location + afterRange.length <= ns.length,
           ns.substring(with: beforeRange) == marker, ns.substring(with: afterRange) == marker {
            let fullRange = NSRange(
                location: beforeRange.location,
                length: markerLength + bounded.length + markerLength
            )
            let newText = ns.replacingCharacters(in: fullRange, with: selectedText)
            return (newText, NSRange(location: beforeRange.location, length: bounded.length))
        }

        let replacement = marker + selectedText + marker
        let newText = ns.replacingCharacters(in: bounded, with: replacement)
        return (newText, NSRange(location: bounded.location + markerLength, length: bounded.length))
    }

    // MARK: - Headings (replace, never stack)

    private static func applyHeading(
        level: Int,
        text: String,
        selection: NSRange
    ) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)
        let lineRange = ns.lineRange(for: NSRange(location: bounded.location, length: 0))
        var lineContent = ns.substring(with: lineRange)
        if lineContent.hasSuffix("\r\n") {
            lineContent.removeLast(2)
        } else if lineContent.hasSuffix("\n") || lineContent.hasSuffix("\r") {
            lineContent.removeLast()
        }

        var hashCount = 0
        for character in lineContent {
            if character == "#" {
                hashCount += 1
            } else {
                break
            }
        }
        var existingPrefixLength = 0
        if hashCount > 0, hashCount <= 6 {
            let afterHashes = lineContent.index(lineContent.startIndex, offsetBy: hashCount)
            if afterHashes < lineContent.endIndex, lineContent[afterHashes] == " " {
                existingPrefixLength = hashCount + 1
            } else {
                hashCount = 0
            }
        }

        let newPrefix = String(repeating: "#", count: level) + " "
        let replacementPrefix = hashCount == level ? "" : newPrefix
        let prefixRange = NSRange(location: lineRange.location, length: existingPrefixLength)
        let newText = ns.replacingCharacters(in: prefixRange, with: replacementPrefix)
        let delta = (replacementPrefix as NSString).length - existingPrefixLength
        let newLocation = max(lineRange.location, min((newText as NSString).length, bounded.location + delta))
        return (newText, NSRange(location: newLocation, length: 0))
    }

    // MARK: - Line-prefix actions (bullet list, blockquote)

    private static func applyLinePrefix(
        prefix: String, text: String, selection: NSRange
    ) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)
        var lines = ns.components(separatedBy: "\n")
        let touched = touchedLineIndices(lines: lines, selection: bounded)

        let allHavePrefix = touched.allSatisfy { lines[$0].hasPrefix(prefix) }
        for index in touched {
            if allHavePrefix {
                lines[index] = String(lines[index].dropFirst(prefix.count))
            } else if !lines[index].hasPrefix(prefix) {
                lines[index] = prefix + lines[index]
            }
        }

        let newText = lines.joined(separator: "\n")
        let delta = allHavePrefix ? -(prefix as NSString).length : (prefix as NSString).length
        return (
            newText,
            clampedSelection(location: bounded.location + delta, length: bounded.length, in: newText as NSString)
        )
    }

    // MARK: - Numbered list (restarts at 1 for each application)

    private static func applyNumberedList(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)
        var lines = ns.components(separatedBy: "\n")
        let touched = touchedLineIndices(lines: lines, selection: bounded)

        let allNumbered = touched.allSatisfy { numberedPrefixLength(of: lines[$0]) != nil }
        if allNumbered {
            for index in touched {
                if let length = numberedPrefixLength(of: lines[index]) {
                    lines[index] = String(lines[index].dropFirst(length))
                }
            }
        } else {
            var number = 1
            for index in touched {
                let stripped: String = if let length = numberedPrefixLength(of: lines[index]) {
                    String(lines[index].dropFirst(length))
                } else {
                    lines[index]
                }
                lines[index] = "\(number). \(stripped)"
                number += 1
            }
        }

        let newText = lines.joined(separator: "\n")
        return (newText, clampedSelection(location: bounded.location, length: bounded.length, in: newText as NSString))
    }

    private static func numberedPrefixLength(of line: String) -> Int? {
        var digitCount = 0
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
            digitCount += 1
        }
        guard digitCount > 0, index < line.endIndex, line[index] == "." else { return nil }
        let afterDot = line.index(after: index)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return digitCount + 2
    }

    // MARK: - Task item (checkbox toggle, never duplicates the prefix)

    private static func applyTaskItem(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)
        var lines = ns.components(separatedBy: "\n")
        let touched = touchedLineIndices(lines: lines, selection: bounded)
        let unchecked = "- [ ] "
        let checked = "- [x] "

        for index in touched {
            if lines[index].hasPrefix(unchecked) {
                lines[index] = checked + lines[index].dropFirst(unchecked.count)
            } else if lines[index].hasPrefix(checked) {
                lines[index] = unchecked + lines[index].dropFirst(checked.count)
            } else {
                lines[index] = unchecked + lines[index]
            }
        }

        let newText = lines.joined(separator: "\n")
        return (newText, clampedSelection(location: bounded.location, length: bounded.length, in: newText as NSString))
    }

    // MARK: - Link/image (nested placeholder wrap)

    private static func applyLink(
        isImage: Bool,
        text: String,
        selection: NSRange
    ) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)
        let bang = isImage ? "!" : ""

        if bounded.length == 0 {
            let placeholder = isImage ? "alt text" : "link text"
            let replacement = "\(bang)[\(placeholder)](url)"
            let newText = ns.replacingCharacters(in: bounded, with: replacement)
            let location = bounded.location + (bang as NSString).length + 1
            return (newText, NSRange(location: location, length: (placeholder as NSString).length))
        }

        let selectedText = ns.substring(with: bounded)
        let replacement = "\(bang)[\(selectedText)](url)"
        let newText = ns.replacingCharacters(in: bounded, with: replacement)
        let location = bounded.location + (bang as NSString).length + 1 + (selectedText as NSString).length + 2
        return (newText, NSRange(location: location, length: 3))
    }

    // MARK: - Pasted/dropped image (issue #18 -- always concrete alt text + a real relative

    // path, unlike the toolbar's `.image` placeholder-wrap above, so this is a separate function
    // rather than a new `applyLink` case)

    /// Inserts `![altText](relativePath)` at `selection`'s location (replacing any selected
    /// text), landing the cursor immediately after the inserted link.
    public static func insertImageLink(
        altText: String,
        relativePath: String,
        into text: String,
        at selection: NSRange
    ) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)
        let insertion = "![\(altText)](\(relativePath))"
        let newText = ns.replacingCharacters(in: bounded, with: insertion)
        let location = bounded.location + (insertion as NSString).length
        return (newText, clampedSelection(location: location, length: 0, in: newText as NSString))
    }

    // MARK: - Horizontal rule (ignores selection, own line)

    private static func applyHorizontalRule(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)
        let insertion = "\n\n---\n\n"
        let newText = ns.replacingCharacters(in: NSRange(location: bounded.location, length: 0), with: insertion)
        let location = bounded.location + (insertion as NSString).length
        return (newText, clampedSelection(location: location, length: 0, in: newText as NSString))
    }

    // MARK: - Code block (multi-line fence wrap)

    private static func applyCodeBlock(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)

        if bounded.length == 0 {
            let replacement = "```\n\n```"
            let newText = ns.replacingCharacters(in: bounded, with: replacement)
            return (newText, NSRange(location: bounded.location + 4, length: 0))
        }

        let selectedText = ns.substring(with: bounded)
        let replacement = "```\n\(selectedText)\n```"
        let newText = ns.replacingCharacters(in: bounded, with: replacement)
        return (newText, NSRange(location: bounded.location + 4, length: (selectedText as NSString).length))
    }

    // MARK: - Table (fixed template, ignores selection)

    private static func applyTable(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let bounded = boundedRange(selection, in: ns)
        let template = "\n\n| Header | Header |\n| --- | --- |\n| Cell | Cell |\n\n"
        let newText = ns.replacingCharacters(in: NSRange(location: bounded.location, length: 0), with: template)
        let location = bounded.location + (template as NSString).length
        return (newText, clampedSelection(location: location, length: 0, in: newText as NSString))
    }

    // MARK: - Shared helpers

    private static func boundedRange(_ range: NSRange, in ns: NSString) -> NSRange {
        let location = max(0, min(range.location, ns.length))
        let length = max(0, min(range.length, ns.length - location))
        return NSRange(location: location, length: length)
    }

    private static func clampedSelection(location: Int, length: Int, in ns: NSString) -> NSRange {
        let clampedLocation = max(0, min(location, ns.length))
        let clampedLength = max(0, min(length, ns.length - clampedLocation))
        return NSRange(location: clampedLocation, length: clampedLength)
    }

    private static func touchedLineIndices(lines: [String], selection: NSRange) -> ClosedRange<Int> {
        var offsets: [Int] = []
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += (line as NSString).length + 1
        }
        let selectionStart = selection.location
        let selectionEnd = selection.location + selection.length
        var firstIndex = 0
        var lastIndex = lines.count - 1
        for (index, start) in offsets.enumerated() {
            let end = start + (lines[index] as NSString).length
            if selectionStart >= start, selectionStart <= end {
                firstIndex = index
            }
            if selectionEnd >= start, selectionEnd <= end {
                lastIndex = index
            }
        }
        return min(firstIndex, lastIndex) ... max(firstIndex, lastIndex)
    }
}
