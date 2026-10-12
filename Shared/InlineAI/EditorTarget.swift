import Foundation

/// The text an inline AI action works on: what you selected, or the paragraph around the caret
/// when nothing is selected (issue #6).
public struct EditorTarget: Equatable, Sendable {
    public enum Kind: Sendable {
        case selection
        case paragraph
    }

    public let kind: Kind
    /// Where `text` sits in the document, in UTF-16 units.
    public let range: NSRange
    public let text: String

    /// Longer text is refused, so one click can't send a huge request.
    public static let maximumLength = 20000

    /// `nil` when there is nothing to work on: a blank line, only whitespace, or too much text.
    public static func resolve(in document: String, selected: NSRange) -> EditorTarget? {
        let source = document as NSString
        guard selected.location != NSNotFound, NSMaxRange(selected) <= source.length else { return nil }
        let isSelection = selected.length > 0
        let range = isSelection ? selected : EditorSelection.paragraphRange(in: source, around: selected.location)
        guard range.length > 0, range.length <= maximumLength else { return nil }
        let text = source.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return EditorTarget(kind: isSelection ? .selection : .paragraph, range: range, text: text)
    }
}
