import Highlightr
import SwiftUI

/// Shared helper: pick a readable caret/insertion-point color for a background.
@MainActor
func caretColor(for background: PlatformColor) -> PlatformColor {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    #if os(macOS)
        (background.usingColorSpace(.deviceRGB) ?? background).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    #else
        background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    #endif
    let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
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
        var scrollFraction: CGFloat = 0
        var isScrollSyncEnabled: Bool = false
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
            textStorage.highlightr.theme.setCodeFont(font)

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
            textView.isRichText = true // required for attributed (highlighted) text to render
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

            var needsFullRehighlight = false

            if context.coordinator.themeName != highlightThemeName {
                textStorage.highlightr.setTheme(to: highlightThemeName)
                textStorage.highlightr.theme.setCodeFont(font)
                context.coordinator.themeName = highlightThemeName
                let background = textStorage.highlightr.theme.themeBackgroundColor ?? .textBackgroundColor
                textView.backgroundColor = background
                textView.insertionPointColor = caretColor(for: background)
                needsFullRehighlight = true
            } else if textStorage.highlightr.theme.codeFont != font {
                textStorage.highlightr.theme.setCodeFont(font)
                needsFullRehighlight = true
            }

            if textView.font != font {
                textView.font = font
                needsFullRehighlight = true
            }

            if needsFullRehighlight {
                // CodeAttributedString.processEditing() only re-highlights the edited
                // paragraph on a text change; re-triggering `language`'s didSet forces
                // a full re-highlight so already-typed text picks up the new font/theme.
                // (Swift forbids `language = language`, so route through nil first.)
                let language = textStorage.language
                textStorage.language = nil
                textStorage.language = language
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

            context.coordinator.parent = self
            if isScrollSyncEnabled {
                context.coordinator.applyScrollFraction(scrollFraction, to: scrollView)
            }
        }

        class Coordinator: NSObject, NSTextViewDelegate {
            var parent: MarkdownTextView
            weak var textView: MarkdownNSTextView?
            var themeName: String
            private var isApplyingExternalScroll = false
            private var lastAppliedScrollFraction: CGFloat?
            private var anchors: [EditorLineAnchor] = []
            private var anchorText: String?
            private var anchorHeight: CGFloat = 0

            init(_ parent: MarkdownTextView) {
                self.parent = parent
                themeName = parent.highlightThemeName
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                parent.text = textView.string
                parent.onTextChange?()
            }

            /// Rebuilds the source-line ↔ pixel-fraction anchor table if the text or laid-out
            /// height changed since the last build (word wrap makes a naive line-count fraction
            /// diverge from where a line actually sits once laid out).
            @MainActor
            private func refreshAnchorsIfNeeded(text: String, totalHeight: CGFloat, visibleHeight: CGFloat) {
                guard text != anchorText || totalHeight != anchorHeight else { return }
                anchorText = text
                anchorHeight = totalHeight
                anchors = computeEditorLineAnchors(
                    text: text, totalHeight: totalHeight, visibleHeight: visibleHeight
                ) { [weak textView] charIndex in
                    textView?.lineTop(forCharacterIndex: charIndex)
                }
            }

            @MainActor @objc func scrollViewDidScroll(_: Notification) {
                guard !isApplyingExternalScroll,
                      let textView, let scrollView = textView.enclosingScrollView else { return }
                let contentView = scrollView.contentView
                let visibleHeight = contentView.bounds.height
                let totalHeight = textView.contentHeightExcludingScrollPastEnd
                guard totalHeight > visibleHeight else { return }
                refreshAnchorsIfNeeded(text: textView.string, totalHeight: totalHeight, visibleHeight: visibleHeight)
                let pixelFraction = max(0, min(1, contentView.bounds.origin.y / (totalHeight - visibleHeight)))
                let sourceFraction = interpolateEditorAnchor(
                    anchors, from: \.rendered, to: \.source, value: pixelFraction
                )
                lastAppliedScrollFraction = sourceFraction
                parent.onScroll?(sourceFraction)
            }

            @MainActor func applyScrollFraction(_ fraction: CGFloat, to scrollView: NSScrollView) {
                guard lastAppliedScrollFraction == nil || abs(fraction - lastAppliedScrollFraction!) > 0.001
                else { return }
                let contentView = scrollView.contentView
                guard let documentView = scrollView.documentView as? MarkdownNSTextView else { return }
                let visibleHeight = contentView.bounds.height
                // Uses real content height, not the scroll-past-end padded frame, so fraction 1.0
                // lands on the document's actual last line instead of the blank padding below it.
                let totalHeight = documentView.contentHeightExcludingScrollPastEnd
                guard totalHeight > visibleHeight else { return }
                refreshAnchorsIfNeeded(
                    text: documentView.string,
                    totalHeight: totalHeight,
                    visibleHeight: visibleHeight
                )
                lastAppliedScrollFraction = fraction
                isApplyingExternalScroll = true
                let pixelFraction = interpolateEditorAnchor(anchors, from: \.source, to: \.rendered, value: fraction)
                let targetY = pixelFraction * (totalHeight - visibleHeight)
                contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: targetY))
                scrollView.reflectScrolledClipView(contentView)
                isApplyingExternalScroll = false
            }
        }
    }

    /// Custom NSTextView with scroll-past-end and editor features.
    class MarkdownNSTextView: NSTextView {
        var scrollsPastEnd = true

        /// The document's real content height, excluding the blank padding
        /// `setFrameSize` adds below the last line when `scrollsPastEnd` is
        /// on. Scroll-fraction math must use this instead of `frame.height`,
        /// or fraction 1.0 lands inside that padding instead of on the
        /// actual last line.
        var contentHeightExcludingScrollPastEnd: CGFloat {
            guard let layoutManager, let textContainer else { return frame.height }
            let usedRect = layoutManager.usedRect(for: textContainer)
            return usedRect.height + 2 * textContainerInset.height
        }

        /// The laid-out y-position of the line fragment containing `index`, in the
        /// same coordinate space as `contentHeightExcludingScrollPastEnd`. Returns
        /// nil for an out-of-range index (e.g. the trailing empty line after a
        /// final newline) so callers can skip that sample.
        func lineTop(forCharacterIndex index: Int) -> CGFloat? {
            guard let layoutManager, let textContainer else { return nil }
            let length = (string as NSString).length
            guard index >= 0, index < length else { return nil }
            layoutManager.ensureLayout(for: textContainer)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            return rect.origin.y + textContainerInset.height
        }

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
#endif
