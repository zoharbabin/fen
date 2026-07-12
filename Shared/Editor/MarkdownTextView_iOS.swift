#if !os(macOS)
    import Highlightr
    import SwiftUI
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
        var scrollFraction: CGFloat = 0
        var isScrollSyncEnabled: Bool = false
        var onScroll: ((CGFloat) -> Void)?
        var onTextChange: (() -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> UITextView {
            let textStorage = CodeAttributedString()
            textStorage.language = "markdown"
            textStorage.highlightr.setTheme(to: highlightThemeName)
            textStorage.highlightr.theme.setCodeFont(font)

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
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )

            textView.text = text
            textView.delegate = context.coordinator
            context.coordinator.textView = textView

            if scrollsPastEnd {
                textView.contentInset.bottom = 300
            }
            textView.keyboardDismissMode = .interactive

            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.applyFormattingNotification(_:)),
                name: .insertMarkdownFormatting,
                object: nil
            )

            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            guard let textStorage = textView.textStorage as? CodeAttributedString else { return }

            var needsFullRehighlight = false

            if context.coordinator.themeName != highlightThemeName {
                textStorage.highlightr.setTheme(to: highlightThemeName)
                textStorage.highlightr.theme.setCodeFont(font)
                context.coordinator.themeName = highlightThemeName
                let background = textStorage.highlightr.theme.themeBackgroundColor ?? .systemBackground
                textView.backgroundColor = background
                textView.tintColor = caretColor(for: background)
                needsFullRehighlight = true
            } else if textStorage.highlightr.theme.codeFont != font {
                textStorage.highlightr.theme.setCodeFont(font)
                needsFullRehighlight = true
            }

            if textView.text != text {
                let selectedRange = textView.selectedRange
                textView.text = text
                textView.selectedRange = selectedRange
            }

            if textView.font != font {
                textView.font = font
                needsFullRehighlight = true
            }
            textView.textContainerInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )

            if needsFullRehighlight {
                // CodeAttributedString.processEditing() only re-highlights the edited
                // paragraph on a text change; re-triggering `language`'s didSet forces
                // a full re-highlight so already-typed text picks up the new font/theme.
                // (Swift forbids `language = language`, so route through nil first.)
                let language = textStorage.language
                textStorage.language = nil
                textStorage.language = language
            }

            context.coordinator.parent = self
            if isScrollSyncEnabled {
                context.coordinator.applyScrollFraction(scrollFraction, to: textView)
            }
        }

        class Coordinator: NSObject, UITextViewDelegate {
            var parent: MarkdownTextView
            weak var textView: UITextView?
            var themeName: String
            private var isApplyingExternalScroll = false
            private var lastAppliedScrollFraction: CGFloat?
            private var lastAppliedContentHeight: CGFloat?
            private var anchors: [EditorLineAnchor] = []
            private var anchorText: String?
            private var anchorHeight: CGFloat = 0

            init(_ parent: MarkdownTextView) {
                self.parent = parent
                themeName = parent.highlightThemeName
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
                parent.onTextChange?()
            }

            @objc func applyFormattingNotification(_ notification: Notification) {
                guard let identifier = notification.object as? String,
                      let action = FormattingAction(identifier: identifier),
                      let textView else { return }
                let selection = textView.selectedRange
                let result = MarkdownFormatting.apply(action, to: textView.text, selection: selection)
                textView.text = result.text
                textView.selectedRange = result.selection
                parent.text = result.text
                parent.onTextChange?()
            }

            /// Rebuilds the source-line ↔ pixel-fraction anchor table if the text or laid-out
            /// height changed since the last build (word wrap makes a naive line-count fraction
            /// diverge from where a line actually sits once laid out).
            private func refreshAnchorsIfNeeded(textView: UITextView, totalHeight: CGFloat, visibleHeight: CGFloat) {
                let text = textView.text
                guard text != anchorText || totalHeight != anchorHeight else { return }
                anchorText = text
                anchorHeight = totalHeight
                anchors = computeEditorLineAnchors(
                    text: text, totalHeight: totalHeight, visibleHeight: visibleHeight
                ) { [weak textView] charIndex in
                    guard let textView else { return nil }
                    let layoutManager = textView.layoutManager
                    let textContainer = textView.textContainer
                    let length = (textView.text as NSString).length
                    guard charIndex >= 0, charIndex < length else { return nil }
                    layoutManager.ensureLayout(for: textContainer)
                    let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                    let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                    return rect.origin.y + textView.textContainerInset.top
                }
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                guard !isApplyingExternalScroll, let textView = scrollView as? UITextView else { return }
                let contentHeight = scrollView.contentSize.height
                let visibleHeight = scrollView.bounds.height
                guard contentHeight > visibleHeight else { return }
                refreshAnchorsIfNeeded(textView: textView, totalHeight: contentHeight, visibleHeight: visibleHeight)
                let offset = scrollView.contentOffset.y
                let pixelFraction = max(0, min(1, offset / (contentHeight - visibleHeight)))
                let sourceFraction = interpolateEditorAnchor(
                    anchors, from: \.rendered, to: \.source, value: pixelFraction
                )
                lastAppliedScrollFraction = sourceFraction
                parent.onScroll?(sourceFraction)
            }

            func applyScrollFraction(_ fraction: CGFloat, to textView: UITextView) {
                let contentHeight = textView.contentSize.height
                let visibleHeight = textView.bounds.height
                guard contentHeight > visibleHeight else { return }
                // A font-size zoom changes contentHeight without changing fraction (zoom never
                // touches ScrollSync), so a fraction-only check would otherwise skip reapplying
                // and leave the pixel offset stale relative to the layout that just changed
                // underneath it -- re-checking contentHeight here is what keeps a zoom step from
                // silently desyncing the editor from the preview.
                guard lastAppliedScrollFraction == nil
                    || abs(fraction - lastAppliedScrollFraction!) > 0.001
                    || lastAppliedContentHeight != contentHeight
                else { return }
                refreshAnchorsIfNeeded(textView: textView, totalHeight: contentHeight, visibleHeight: visibleHeight)
                lastAppliedScrollFraction = fraction
                lastAppliedContentHeight = contentHeight
                isApplyingExternalScroll = true
                let pixelFraction = interpolateEditorAnchor(anchors, from: \.source, to: \.rendered, value: fraction)
                let targetY = pixelFraction * (contentHeight - visibleHeight)
                textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: targetY), animated: false)
                isApplyingExternalScroll = false
            }
        }
    }
#endif
