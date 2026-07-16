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

            textView.baseHorizontalInset = horizontalInset
            textView.isWidthLimited = isWidthLimited
            textView.maximumWidth = maximumWidth
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

            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.applyFormattingNotification(_:)),
                name: .insertMarkdownFormatting,
                object: nil
            )

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

            textView.baseHorizontalInset = horizontalInset
            textView.isWidthLimited = isWidthLimited
            textView.maximumWidth = maximumWidth
            textView.verticalInset = verticalInset
            textView.applyWidthLimitedInset()

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
            private var lastAppliedTotalHeight: CGFloat?
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

            // MARK: - Tab/Backspace/Enter/Home key handling (issues #15, #17, #51)

            @MainActor func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
                let preferences = Preferences.shared
                switch selector {
                case #selector(NSResponder.insertTab(_:)):
                    guard preferences.editorConvertTabs, textView.selectedRange().length == 0 else { return false }
                    insertTabAsSpaces(in: textView)
                    return true
                case #selector(NSResponder.deleteBackward(_:)):
                    guard textView.selectedRange().length == 0 else { return false }
                    return handleBackspace(in: textView)
                case #selector(NSResponder.insertNewline(_:)):
                    guard preferences.editorInsertPrefixInBlock, textView.selectedRange().length == 0 else {
                        return false
                    }
                    return handleNewline(in: textView, autoIncrement: preferences.editorAutoIncrementNumberedLists)
                case #selector(NSResponder.moveToLeftEndOfLine(_:)),
                     #selector(NSResponder.moveToBeginningOfLine(_:)),
                     #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                    // AppKit's StandardKeyBinding.dict binds the plain Home key to
                    // scrollToBeginningOfDocument:, not moveToBeginningOfLine:/moveToLeftEndOfLine:
                    // (those need Control+Home) -- so the plain key must be intercepted here too.
                    guard preferences.editorSmartHome else { return false }
                    return handleSmartHome(in: textView)
                default:
                    return false
                }
            }

            @MainActor func textView(
                _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
            ) -> Bool {
                guard Preferences.shared.editorCompleteMatchingCharacters,
                      let replacementString, replacementString.count == 1,
                      let character = replacementString.first else { return true }
                return !applyPairDecision(for: character, in: textView, range: range)
            }

            /// Inserts spaces to the next tab stop at the cursor's column, and reports the
            /// edit through the same `textDidChange` path a real keystroke would take (this
            /// method fires *instead of* the normal keystroke once `doCommandBySelector`
            /// returns true, so `NSTextView` never generates its own change notification here).
            @MainActor private func insertTabAsSpaces(in textView: NSTextView) {
                let location = textView.selectedRange().location
                let column = columnOfCharacter(at: location, in: textView.string)
                let spaces = MarkdownTextEditing.tabInsertion(atColumn: column)
                replaceAndNotify(in: textView, range: NSRange(location: location, length: 0), with: spaces)
            }

            /// Returns `true` if this Backspace was fully handled here (outdent or atomic pair
            /// deletion), `false` to let `NSTextView` perform its normal single-character delete.
            @MainActor private func handleBackspace(in textView: NSTextView) -> Bool {
                let location = textView.selectedRange().location
                let ns = textView.string as NSString

                if Preferences.shared.editorConvertTabs {
                    let column = columnOfCharacter(at: location, in: textView.string)
                    let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
                    let prefix = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
                    if column > 0, let outdent = MarkdownTextEditing.outdentAmount(linePrefix: prefix) {
                        replaceAndNotify(
                            in: textView, range: NSRange(location: location - outdent, length: outdent), with: ""
                        )
                        return true
                    }
                }

                if Preferences.shared.editorCompleteMatchingCharacters, location > 0, location < ns.length {
                    let before = Character(ns.substring(with: NSRange(location: location - 1, length: 1)))
                    let after = Character(ns.substring(with: NSRange(location: location, length: 1)))
                    if MarkdownTextEditing.isAtomicPairDeletion(before: before, after: after) {
                        replaceAndNotify(
                            in: textView, range: NSRange(location: location - 1, length: 2), with: ""
                        )
                        return true
                    }
                }

                return false
            }

            /// Returns `true` if Enter was handled here (list/blockquote continuation or
            /// termination), `false` to let `NSTextView` insert a plain newline.
            @MainActor private func handleNewline(in textView: NSTextView, autoIncrement: Bool) -> Bool {
                let location = textView.selectedRange().location
                let ns = textView.string as NSString
                let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
                // Only continue when the caret is at the true end of the line -- matching
                // MacDown's original behavior of not continuing mid-line.
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

            /// Returns `true` if Home was handled here (moved to first-non-whitespace or column
            /// 0), `false` to let `NSTextView` perform its normal Home behavior (e.g. on a
            /// soft-wrapped visual row, where smart Home doesn't apply).
            @MainActor private func handleSmartHome(in textView: NSTextView) -> Bool {
                let location = textView.selectedRange().location
                let ns = textView.string as NSString
                let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))

                // Guard against soft-wrapped lines: if the line's start and the caret's current
                // position aren't on the same laid-out visual row, this is a wrapped row, not a
                // true line start -- fall back to normal behavior (matches MacDown's fix for its
                // own issue #103).
                if let layoutManager = textView.layoutManager, ns.length > 0 {
                    let lastCharacterIndex = ns.length - 1
                    let lineGlyphIndex = layoutManager.glyphIndexForCharacter(at: min(
                        lineRange.location,
                        lastCharacterIndex
                    ))
                    let caretGlyphIndex = layoutManager.glyphIndexForCharacter(at: min(location, lastCharacterIndex))
                    let lineFragmentTop = layoutManager
                        .lineFragmentRect(forGlyphAt: lineGlyphIndex, effectiveRange: nil).origin.y
                    let caretFragmentTop = layoutManager.lineFragmentRect(
                        forGlyphAt: caretGlyphIndex,
                        effectiveRange: nil
                    ).origin.y
                    if lineFragmentTop != caretFragmentTop {
                        return false
                    }
                }

                let line = ns.substring(with: lineRange)
                let trimmedLine = line.hasSuffix("\n") ? String(line.dropLast()) : line
                let caretColumn = location - lineRange.location
                let targetColumn = MarkdownTextEditing.smartHomeColumn(
                    line: Substring(trimmedLine), caretColumn: caretColumn
                )
                textView.setSelectedRange(NSRange(location: lineRange.location + targetColumn, length: 0))
                return true
            }

            /// Applies `MarkdownTextEditing.pairDecision` for a just-typed character. Returns
            /// `true` if this method fully handled the edit (the caller must then suppress the
            /// original `shouldChangeTextIn` edit), `false` to let it proceed normally.
            @MainActor private func applyPairDecision(
                for character: Character,
                in textView: NSTextView,
                range: NSRange
            ) -> Bool {
                let ns = textView.string as NSString
                let hasSelection = range.length > 0
                let nextCharacter: Character? = (!hasSelection && range.location < ns.length)
                    ? Character(ns.substring(with: NSRange(location: range.location, length: 1)))
                    : nil

                switch MarkdownTextEditing.pairDecision(
                    for: character, nextCharacter: nextCharacter, hasSelection: hasSelection
                ) {
                case let .insertPair(opening, closing):
                    replaceAndNotify(in: textView, range: range, with: "\(opening)\(closing)")
                    textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                    return true
                case .skipOver:
                    textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                    return true
                case let .wrapSelection(opening, closing):
                    let selected = ns.substring(with: range)
                    replaceAndNotify(in: textView, range: range, with: "\(opening)\(selected)\(closing)")
                    textView.setSelectedRange(NSRange(location: range.location + 1, length: range.length))
                    return true
                case .insertPlain:
                    return false
                }
            }

            /// The 0-based column of `location` on its own line (distance from the start of the
            /// line, not the whole document).
            @MainActor private func columnOfCharacter(at location: Int, in text: String) -> Int {
                let ns = text as NSString
                let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
                return location - lineStart
            }

            /// Performs a text replacement the same way a real keystroke would: through
            /// `NSTextView.insertText`-equivalent undo-registered replacement, then notifying
            /// `parent`/`onTextChange` exactly like `textDidChange` does, since these
            /// programmatic edits bypass the normal `NSText` notification chain.
            @MainActor private func replaceAndNotify(
                in textView: NSTextView,
                range: NSRange,
                with replacement: String
            ) {
                guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
                parent.text = textView.string
                parent.onTextChange?()
            }

            @MainActor @objc func applyFormattingNotification(_ notification: Notification) {
                guard let identifier = notification.object as? String,
                      let action = FormattingAction(identifier: identifier),
                      let textView else { return }
                let selection = textView.selectedRange()
                let result = MarkdownFormatting.apply(action, to: textView.string, selection: selection)
                textView.string = result.text
                textView.setSelectedRange(result.selection)
                parent.text = result.text
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
                let contentView = scrollView.contentView
                guard let documentView = scrollView.documentView as? MarkdownNSTextView else { return }
                let visibleHeight = contentView.bounds.height
                // Uses real content height, not the scroll-past-end padded frame, so fraction 1.0
                // lands on the document's actual last line instead of the blank padding below it.
                let totalHeight = documentView.contentHeightExcludingScrollPastEnd
                guard totalHeight > visibleHeight else { return }
                // A font-size zoom changes totalHeight without changing fraction (zoom never
                // touches ScrollSync), so the fraction-only check below would otherwise skip
                // reapplying and leave the pixel offset stale relative to the layout that just
                // changed underneath it -- re-checking totalHeight here is what keeps a zoom step
                // from silently desyncing the editor from the preview.
                guard lastAppliedScrollFraction == nil
                    || abs(fraction - lastAppliedScrollFraction!) > 0.001
                    || lastAppliedTotalHeight != totalHeight
                else { return }
                refreshAnchorsIfNeeded(
                    text: documentView.string,
                    totalHeight: totalHeight,
                    visibleHeight: visibleHeight
                )
                lastAppliedScrollFraction = fraction
                lastAppliedTotalHeight = totalHeight
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

        // MARK: - Limit editor width (issue #50)

        var baseHorizontalInset: CGFloat = 15
        var verticalInset: CGFloat = 30
        var isWidthLimited = false
        var maximumWidth: CGFloat = 800

        /// Recomputes `textContainerInset`'s horizontal component from the view's current
        /// width -- call on every width change and once on initial load (see
        /// `widthLimitedHorizontalInset`'s doc comment for why both call sites matter).
        func applyWidthLimitedInset() {
            let inset = MarkdownTextEditing.widthLimitedHorizontalInset(
                viewWidth: frame.width,
                baseInset: baseHorizontalInset,
                isWidthLimited: isWidthLimited,
                maximumWidth: maximumWidth
            )
            textContainerInset = NSSize(width: inset, height: verticalInset)
        }

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
            let widthChanged = adjustedSize.width != frame.width
            super.setFrameSize(adjustedSize)
            // Recompute on every width change, not just once -- MacDown's own issue #288 was
            // exactly this check being skipped on resize.
            if widthChanged, isWidthLimited {
                applyWidthLimitedInset()
            }
        }
    }
#endif
