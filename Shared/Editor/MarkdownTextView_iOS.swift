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
        var isWidthLimited: Bool = false
        var maximumWidth: CGFloat = 800
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

            let textView = MarkdownUITextView(frame: .zero, textContainer: textContainer)
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

            textView.baseHorizontalInset = horizontalInset
            textView.verticalInset = verticalInset
            textView.isWidthLimited = isWidthLimited
            textView.maximumWidth = maximumWidth
            textView.applyWidthLimitedInset()

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
            if let widthLimitedTextView = textView as? MarkdownUITextView {
                widthLimitedTextView.baseHorizontalInset = horizontalInset
                widthLimitedTextView.verticalInset = verticalInset
                widthLimitedTextView.isWidthLimited = isWidthLimited
                widthLimitedTextView.maximumWidth = maximumWidth
                widthLimitedTextView.applyWidthLimitedInset()
            } else {
                textView.textContainerInset = UIEdgeInsets(
                    top: verticalInset,
                    left: horizontalInset,
                    bottom: verticalInset,
                    right: horizontalInset
                )
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

            context.coordinator.parent = self
            if isScrollSyncEnabled {
                context.coordinator.applyScrollFraction(scrollFraction, to: textView)
            }
        }

        /// A `UITextView` subclass that recomputes its horizontal inset on every bounds change,
        /// not only when `isWidthLimited`/`maximumWidth` are set from `updateUIView` -- mirroring
        /// `MarkdownNSTextView`'s `setFrameSize` hook on macOS, since a rotation or split-view
        /// resize changes `bounds.width` without SwiftUI re-invoking `updateUIView`.
        class MarkdownUITextView: UITextView {
            var baseHorizontalInset: CGFloat = 15
            var verticalInset: CGFloat = 30
            var isWidthLimited = false
            var maximumWidth: CGFloat = 800

            func applyWidthLimitedInset() {
                let inset = MarkdownTextEditing.widthLimitedHorizontalInset(
                    viewWidth: bounds.width,
                    baseInset: baseHorizontalInset,
                    isWidthLimited: isWidthLimited,
                    maximumWidth: maximumWidth
                )
                textContainerInset = UIEdgeInsets(top: verticalInset, left: inset, bottom: verticalInset, right: inset)
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                if isWidthLimited {
                    applyWidthLimitedInset()
                }
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

            // MARK: - Tab/Backspace/Enter key handling (issues #15, #17)

            /// UIKit funnels every insertion, deletion, and replacement through this one
            /// delegate method (there's no `doCommandBySelector` equivalent on iOS), so Tab,
            /// Backspace, Enter, and auto-pair are all recognized here by `range`/`text` shape:
            /// Backspace is an empty replacement over a non-empty range; Tab/Enter/a single
            /// pairable character are single-character insertions.
            func textView(
                _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
            ) -> Bool {
                let preferences = Preferences.shared

                if text.isEmpty, range.length == 1 {
                    return !handleBackspace(in: textView, range: range, preferences: preferences)
                }
                if text == "\t" {
                    guard preferences.editorConvertTabs, range.length == 0 else { return true }
                    insertTabAsSpaces(in: textView, at: range.location)
                    return false
                }
                if text == "\n" {
                    guard preferences.editorInsertPrefixInBlock, range.length == 0 else { return true }
                    return !handleNewline(
                        in: textView, at: range.location, autoIncrement: preferences.editorAutoIncrementNumberedLists
                    )
                }
                if preferences.editorCompleteMatchingCharacters, text.count == 1, let character = text.first {
                    return !applyPairDecision(for: character, in: textView, range: range)
                }
                return true
            }

            private func insertTabAsSpaces(in textView: UITextView, at location: Int) {
                let column = columnOfCharacter(at: location, in: textView.text)
                let spaces = MarkdownTextEditing.tabInsertion(atColumn: column)
                replaceAndNotify(in: textView, range: NSRange(location: location, length: 0), with: spaces)
            }

            private func handleBackspace(in textView: UITextView, range: NSRange, preferences: Preferences) -> Bool {
                let location = range.location + range.length
                let ns = textView.text as NSString

                if preferences.editorConvertTabs {
                    let column = columnOfCharacter(at: location, in: textView.text)
                    let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
                    let prefix = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
                    if column > 0, let outdent = MarkdownTextEditing.outdentAmount(linePrefix: prefix) {
                        replaceAndNotify(
                            in: textView, range: NSRange(location: location - outdent, length: outdent), with: ""
                        )
                        return true
                    }
                }

                if preferences.editorCompleteMatchingCharacters, location > 0, location < ns.length {
                    let before = Character(ns.substring(with: NSRange(location: location - 1, length: 1)))
                    let after = Character(ns.substring(with: NSRange(location: location, length: 1)))
                    if MarkdownTextEditing.isAtomicPairDeletion(before: before, after: after) {
                        replaceAndNotify(in: textView, range: NSRange(location: location - 1, length: 2), with: "")
                        return true
                    }
                }

                return false
            }

            private func handleNewline(in textView: UITextView, at location: Int, autoIncrement: Bool) -> Bool {
                let ns = textView.text as NSString
                let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
                var contentEnd = lineRange.location + lineRange.length
                if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 10 {
                    contentEnd -= 1
                }
                if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 13 {
                    contentEnd -= 1
                }
                guard location == contentEnd else { return false }

                let line = ns.substring(with: NSRange(
                    location: lineRange.location,
                    length: contentEnd - lineRange.location
                ))
                switch MarkdownTextEditing.continuationAction(forLine: line, autoIncrement: autoIncrement) {
                case let .continuePrefix(prefix):
                    replaceAndNotify(in: textView, range: NSRange(location: location, length: 0), with: "\n" + prefix)
                    return true
                case .terminateList:
                    replaceAndNotify(
                        in: textView,
                        range: NSRange(location: lineRange.location, length: location - lineRange.location),
                        with: ""
                    )
                    return true
                case .none:
                    return false
                }
            }

            private func applyPairDecision(for character: Character, in textView: UITextView, range: NSRange) -> Bool {
                let ns = textView.text as NSString
                let hasSelection = range.length > 0
                let nextCharacter: Character? = (!hasSelection && range.location < ns.length)
                    ? Character(ns.substring(with: NSRange(location: range.location, length: 1)))
                    : nil

                switch MarkdownTextEditing.pairDecision(
                    for: character, nextCharacter: nextCharacter, hasSelection: hasSelection
                ) {
                case let .insertPair(opening, closing):
                    replaceAndNotify(in: textView, range: range, with: "\(opening)\(closing)")
                    textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                    return true
                case .skipOver:
                    textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                    return true
                case let .wrapSelection(opening, closing):
                    let selected = ns.substring(with: range)
                    replaceAndNotify(in: textView, range: range, with: "\(opening)\(selected)\(closing)")
                    textView.selectedRange = NSRange(location: range.location + 1, length: range.length)
                    return true
                case .insertPlain:
                    return false
                }
            }

            private func columnOfCharacter(at location: Int, in text: String) -> Int {
                let ns = text as NSString
                let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
                return location - lineStart
            }

            /// Performs a text replacement and notifies `parent`/`onTextChange` the same way
            /// `textViewDidChange` does, since this bypasses the normal delegate change callback.
            /// Assigning `UITextView.text` (unlike a real keystroke) resets `selectedRange` to the
            /// end of the document, so this restores the caret to where the replacement leaves it.
            private func replaceAndNotify(in textView: UITextView, range: NSRange, with replacement: String) {
                let ns = textView.text as NSString
                textView.text = ns.replacingCharacters(in: range, with: replacement)
                textView.selectedRange = MarkdownTextEditing.selectionAfterReplacement(
                    range: range, replacementLength: (replacement as NSString).length
                )
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
