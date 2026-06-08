import Foundation
import Highlightr

/// Editor syntax highlighting is performed live by Highlightr's
/// `CodeAttributedString` inside `MarkdownTextView`. This namespace just
/// exposes the list of available themes for the Settings picker.
@MainActor
enum MarkdownSyntaxHighlighter {
    /// Available Highlightr (highlight.js) themes, sorted alphabetically.
    static var availableThemes: [String] {
        (Highlightr()?.availableThemes() ?? []).sorted()
    }
}
