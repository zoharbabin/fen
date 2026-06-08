import SwiftUI
import Highlightr

/// Shared helper: pick a readable caret/insertion-point color for a background.
@MainActor
private func caretColor(for background: PlatformColor) -> PlatformColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    #if os(macOS)
    (background.usingColorSpace(.deviceRGB) ?? background).getRed(&r, green: &g, blue: &b, alpha: &a)
    #else
    background.getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b
    return luminance < 0.5 ? .white : .black
}

#if os(macOS)
import AppKit

/// NSTextView-backed markdown editor for macOS with live syntax highlighting.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var highlightThemeName: String
    var lineSpacing: CGFloat
    var horizontalInset: CGFloat
    var verticalInset: CGFloat
    var isEditable: Bool
    var scrollsPastEnd: Bool
    var onScroll: ((CGFloat) -> Void)?
    var onTextChange: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Highlightr's CodeAttributedString is an NSTextStorage that
        // re-highlights its contents as Markdown whenever they change.
        let textStorage = CodeAttributedString()
        textStorage.language = "markdown"
        textStorage.highlightr.setTheme(to: highlightThemeName)
        textStorage.highlightr.theme.codeFont = font

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = MarkdownNSTextView(frame: .zero, textContainer: textContainer)
        textView.scrollsPastEnd = scrollsPastEnd
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true   // required for attributed (highlighted) text to render
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = font

        let background = textStorage.highlightr.theme.themeBackgroundColor ?? .textBackgroundColor
        textView.backgroundColor = background
        textView.insertionPointColor = caretColor(for: background)

        textView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        textView.defaultParagraphStyle = paragraphStyle

        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView,
              let textStorage = textView.textStorage as? CodeAttributedString else { return }

        if textStorage.highlightr.theme.codeFont != font {
            textStorage.highlightr.theme.codeFont = font
        }
        if context.coordinator.themeName != highlightThemeName {
            textStorage.highlightr.setTheme(to: highlightThemeName)
            textStorage.highlightr.theme.codeFont = font
            context.coordinator.themeName = highlightThemeName
            let background = textStorage.highlightr.theme.themeBackgroundColor ?? .textBackgroundColor
            textView.backgroundColor = background
            textView.insertionPointColor = caretColor(for: background)
        }

        // Update text only if it changed externally (not from user typing).
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        textView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        textView.defaultParagraphStyle = paragraphStyle
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownNSTextView?
        var themeName: String

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            self.themeName = parent.highlightThemeName
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onTextChange?()
        }

        @MainActor @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let scrollView = textView?.enclosingScrollView else { return }
            let contentView = scrollView.contentView
            let documentView = scrollView.documentView!
            let visibleHeight = contentView.bounds.height
            let totalHeight = documentView.frame.height
            guard totalHeight > visibleHeight else { return }
            let scrollFraction = contentView.bounds.origin.y / (totalHeight - visibleHeight)
            parent.onScroll?(scrollFraction)
        }
    }
}

/// Custom NSTextView with scroll-past-end and editor features.
class MarkdownNSTextView: NSTextView {
    var scrollsPastEnd = true

    override func setFrameSize(_ newSize: NSSize) {
        var adjustedSize = newSize
        if scrollsPastEnd, let scrollView = enclosingScrollView {
            let visibleHeight = scrollView.contentSize.height
            let usedRect = layoutManager?.usedRect(for: textContainer!) ?? .zero
            let contentHeight = usedRect.height + 2 * textContainerInset.height
            let extraSpace = max(0, visibleHeight - 50) // Leave 50pt at bottom
            if contentHeight > visibleHeight {
                adjustedSize.height = max(adjustedSize.height, contentHeight + extraSpace)
            }
        }
        super.setFrameSize(adjustedSize)
    }
}

#else
import UIKit

/// UITextView-backed markdown editor for iOS with live syntax highlighting.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont
    var highlightThemeName: String
    var lineSpacing: CGFloat
    var horizontalInset: CGFloat
    var verticalInset: CGFloat
    var isEditable: Bool
    var scrollsPastEnd: Bool
    var onScroll: ((CGFloat) -> Void)?
    var onTextChange: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textStorage = CodeAttributedString()
        textStorage.language = "markdown"
        textStorage.highlightr.setTheme(to: highlightThemeName)
        textStorage.highlightr.theme.codeFont = font

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)

        let textView = UITextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = font
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no

        let background = textStorage.highlightr.theme.themeBackgroundColor ?? .systemBackground
        textView.backgroundColor = background
        textView.tintColor = caretColor(for: background)

        textView.textContainerInset = UIEdgeInsets(
            top: verticalInset, left: horizontalInset,
            bottom: verticalInset, right: horizontalInset
        )

        textView.text = text
        textView.delegate = context.coordinator

        if scrollsPastEnd {
            textView.contentInset.bottom = 300
        }
        textView.keyboardDismissMode = .interactive

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard let textStorage = textView.textStorage as? CodeAttributedString else { return }

        if context.coordinator.themeName != highlightThemeName {
            textStorage.highlightr.setTheme(to: highlightThemeName)
            textStorage.highlightr.theme.codeFont = font
            context.coordinator.themeName = highlightThemeName
            let background = textStorage.highlightr.theme.themeBackgroundColor ?? .systemBackground
            textView.backgroundColor = background
            textView.tintColor = caretColor(for: background)
        }

        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.text = text
            textView.selectedRange = selectedRange
        }

        textView.font = font
        textView.textContainerInset = UIEdgeInsets(
            top: verticalInset, left: horizontalInset,
            bottom: verticalInset, right: horizontalInset
        )
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        var themeName: String

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            self.themeName = parent.highlightThemeName
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onTextChange?()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let contentHeight = scrollView.contentSize.height
            let visibleHeight = scrollView.bounds.height
            guard contentHeight > visibleHeight else { return }
            let offset = scrollView.contentOffset.y
            let scrollFraction = offset / (contentHeight - visibleHeight)
            parent.onScroll?(max(0, min(1, scrollFraction)))
        }
    }
}
#endif
