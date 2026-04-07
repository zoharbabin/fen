import Foundation
import Highlightr

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Provides syntax highlighting for the markdown editor using Highlightr.
@Observable
final class MarkdownSyntaxHighlighter {
    private let highlightr: Highlightr?
    private var debounceTask: Task<Void, Never>?

    var themeName: String = "atom-one-dark" {
        didSet {
            highlightr?.setTheme(to: themeName)
        }
    }

    init() {
        self.highlightr = Highlightr()
        highlightr?.setTheme(to: themeName)
    }

    /// Returns an NSAttributedString with markdown syntax highlighting applied.
    func highlight(_ text: String) -> NSAttributedString? {
        return highlightr?.highlight(text, as: "markdown")
    }

    /// Apply highlighting to a text view with debouncing.
    func highlightAsync(_ text: String, completion: @escaping @Sendable (NSAttributedString?) -> Void) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let result = self?.highlight(text)
            completion(result)
        }
    }

    /// Available Highlightr themes.
    static var availableThemes: [String] {
        Highlightr()?.availableThemes() ?? []
    }
}
