import SwiftUI

#if os(macOS)
import AppKit

/// NSTextView-backed markdown editor for macOS.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var backgroundColor: NSColor
    var insertionPointColor: NSColor
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

        let textView = MarkdownNSTextView()
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = insertionPointColor

        textView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        // Line spacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        textView.defaultParagraphStyle = paragraphStyle

        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView

        // Observe scroll
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
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }

        // Update text only if it changed externally
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = insertionPointColor
        textView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        textView.defaultParagraphStyle = paragraphStyle
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownNSTextView?

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onTextChange?()
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
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

/// UITextView-backed markdown editor for iOS.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont
    var textColor: UIColor
    var backgroundColor: UIColor
    var insertionPointColor: UIColor
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
        let textView = UITextView()
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.tintColor = insertionPointColor
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no

        textView.textContainerInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )

        // Line spacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        textView.text = text
        textView.delegate = context.coordinator

        if scrollsPastEnd {
            textView.contentInset.bottom = 300
        }

        // Keyboard dismiss
        textView.keyboardDismissMode = .interactive

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.text = text
            textView.selectedRange = selectedRange
        }

        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.tintColor = insertionPointColor
        textView.textContainerInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView

        init(_ parent: MarkdownTextView) {
            self.parent = parent
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
