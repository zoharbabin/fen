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
    import UniformTypeIdentifiers

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
        /// Mirrors `isScrollSyncEnabled`'s threading pattern (issue #19 rule 1.3): the toggle
        /// itself is a single app-wide `Preferences.editorFocusModeEnabled` value, but the
        /// derived dim/centering state stays on this Coordinator instance, never shared.
        var isFocusModeEnabled: Bool = false
        /// Live-preview (WYSIWYG-in-source) styling toggle (issue #2 rule 1.2); threaded like
        /// `isFocusModeEnabled` rather than read directly from `Preferences.shared`.
        var isLivePreviewEnabled: Bool = false
        /// Shows source-line numbers in the editor gutter (issue #21); threaded like `isFocusModeEnabled`.
        var showLineNumbers: Bool = false
        /// The document's on-disk location, used to resolve where a pasted/dropped image's
        /// sidecar folder belongs (issue #18). `nil` for an unsaved document -- that case
        /// declines the paste/drop with an alert rather than guessing a location.
        var documentURL: URL?
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
            // Notifies the coordinator once Highlightr's async re-highlight lands, so focus-mode
            // dim attributes reapply after (never before) it wipes attributes (issue #19 rule 4.3).
            textStorage.highlightDelegate = context.coordinator

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
            // Adds .tiff/.png/etc. to readablePasteboardTypes/acceptableDragTypes -- without
            // this, paste(_:)/drag-drop never calls readSelection(from:type:) for a raw image
            // pasteboard type at all (confirmed empirically, issue #18).
            textView.importsGraphics = true
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
            textView.imagePasteCoordinator = context.coordinator
            context.coordinator.textView = textView
            context.coordinator.documentURL = documentURL

            scrollView.documentView = textView

            context.coordinator.installGutterRulerView(on: scrollView, textView: textView, showing: showLineNumbers)

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

            let focusModeJustToggled = context.coordinator.parent.isFocusModeEnabled != isFocusModeEnabled
            let livePreviewJustToggled = context.coordinator.parent.isLivePreviewEnabled != isLivePreviewEnabled
            context.coordinator.parent = self
            context.coordinator.documentURL = documentURL
            if isScrollSyncEnabled {
                context.coordinator.applyScrollFraction(scrollFraction, to: scrollView)
            }
            // The Preferences-backed toggle itself fires neither textDidChange nor a
            // selection-change notification, so it needs its own trigger here (rule 3.5).
            if focusModeJustToggled {
                context.coordinator.applyFocusModeIfNeeded(in: textView)
            }
            if livePreviewJustToggled {
                context.coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
            }

            scrollView.rulersVisible = showLineNumbers
            context.coordinator.refreshGutterLineStartOffsetsIfNeeded(text: textView.string)
        }

        // `HighlightDelegate` is a nonisolated, unannotated Objective-C protocol, but
        // `CodeAttributedString.highlight(_:)` only ever calls it from `DispatchQueue.main.async`,
        // so `@preconcurrency` documents that real guarantee instead of papering over a race.
        class Coordinator: NSObject, NSTextViewDelegate, ImagePasteCoordinating, @preconcurrency HighlightDelegate {
            var parent: MarkdownTextView
            weak var textView: MarkdownNSTextView?
            var themeName: String
            var documentURL: URL?
            private var isApplyingExternalScroll = false
            private var lastAppliedScrollFraction: CGFloat?
            private var lastAppliedTotalHeight: CGFloat?
            private var anchors: [EditorLineAnchor] = []
            private var anchorText: String?
            private var anchorHeight: CGFloat = 0
            /// The paragraph range currently undimmed by focus mode, or `nil` when off (issue #19
            /// rule 1.1) -- lives on this Coordinator instance only, never shared. Not `private`:
            /// `MarkdownTextView+FocusMode.swift`'s extension needs access from another file.
            var focusModeActiveRange: NSRange?
            /// This Coordinator's own slash-command menu state (issue #1 rule 1.1), constructed
            /// fresh per instance, never shared. Not `private` for the same cross-file reason.
            let slashMenuState = SlashCommandMenuState()
            /// The live popup subview showing `slashMenuState`, or `nil` while no trigger is
            /// active. Not `private` for the same cross-file reason as `slashMenuState`.
            var slashMenuHostingView: NSHostingView<SlashCommandMenuView>?
            /// This Coordinator's own line-start-offset cache for the gutter (issue #21 rule
            /// 1.1), rebuilt only when the text changes (rule 4.2). Not `private`:
            /// `EditorGutterRulerView` and `MarkdownTextView+EditorGutter.swift` read/write these
            /// from other files.
            var gutterLineStartOffsets: [Int] = []
            var gutterText: String?
            /// The ruler view drawing this Coordinator's gutter, installed by
            /// `installGutterRulerView`. Not `private`: `updateNSView` toggles its visibility.
            var gutterRulerView: EditorGutterRulerView?
            /// This Coordinator's own live-preview styling state (issue #2 rule 1.1), never
            /// shared across instances. The text a live-preview styling pass last ran against,
            /// so a no-op call (rule 4.1) can be skipped. Not `private`:
            /// `MarkdownTextView+LivePreview.swift`'s extension needs access from another file.
            var livePreviewStyledText: String?
            /// The paragraph range containing the caret the last time live-preview styling ran
            /// (rule 4.2) -- a pure selection move only re-styles the previous and new caret
            /// paragraphs, never the whole document. Not `private` for the same reason.
            var livePreviewCaretParagraphRange: NSRange?
            /// Decoded inline images, keyed by resolved absolute file path, so a repeated
            /// styling pass never re-reads/re-decodes the same file (rule 4.3). Not `private`
            /// for the same reason.
            var livePreviewImageCache: [String: PlatformImage] = [:]
            /// Checkbox-toggle overlay buttons currently on screen, keyed by their line's start
            /// offset, so a re-style pass can remove/replace just the overlay for the paragraph
            /// it touched instead of rebuilding every overlay on screen. Not `private` for the
            /// same reason.
            var livePreviewCheckboxOverlays: [Int: NSButton] = [:]
            /// Inline-image overlay views currently on screen, keyed by the image construct's
            /// start offset, shown only while the caret is outside that image's paragraph
            /// (reveal-on-cursor). Not `private` for the same reason.
            var livePreviewImageOverlays: [Int: NSImageView] = [:]

            init(_ parent: MarkdownTextView) {
                self.parent = parent
                themeName = parent.highlightThemeName
                super.init()
                slashMenuState.commit = { [weak self] action in
                    self?.commitSlashCommandMenuEntry(action)
                }
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? MarkdownNSTextView else { return }
                parent.text = textView.string
                parent.onTextChange?()
                applyFocusModeIfNeeded(in: textView)
                recenterCaretOnActiveLine(in: textView)
                recomputeSlashMenu(in: textView)
                refreshGutterLineStartOffsetsIfNeeded(text: textView.string)
                applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
            }

            @MainActor func textViewDidChangeSelection(_ notification: Notification) {
                guard let textView = notification.object as? MarkdownNSTextView else { return }
                applyFocusModeIfNeeded(in: textView)
                recenterCaretOnActiveLine(in: textView)
                recomputeSlashMenu(in: textView)
                applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
            }

            /// Writes `data` into the document's sidecar assets folder and inserts a Markdown
            /// image link at `textView`'s current selection (issue #18). Returns `false` --
            /// leaving `textView` untouched -- if there's no on-disk document to anchor the
            /// sidecar folder to, or if the write itself fails, so the caller can fall through
            /// to `super.readSelection(from:type:)`'s default handling.
            @MainActor func insertPastedImage(data: Data, contentType: UTType, into textView: NSTextView) -> Bool {
                guard let documentURL else {
                    presentUnsavedDocumentAlert()
                    return false
                }
                guard let relativePath = ImageSidecarWriter.write(
                    data: data, contentType: contentType, documentURL: documentURL
                ) else {
                    return false
                }

                let altText = (relativePath as NSString).lastPathComponent
                let selection = textView.selectedRange()
                let result = MarkdownFormatting.insertImageLink(
                    altText: altText, relativePath: relativePath, into: textView.string, at: selection
                )
                textView.string = result.text
                textView.setSelectedRange(result.selection)
                parent.text = result.text
                parent.onTextChange?()
                return true
            }

            /// Overridden by `ImagePasteE2ETest` (issue #18, rule 5.3) so an unsaved-document
            /// paste can be exercised headlessly -- `NSAlert.runModal()` blocks indefinitely
            /// without a real user click, confirmed empirically by running it standalone.
            @MainActor var presentUnsavedDocumentAlert: () -> Void = {
                let alert = NSAlert()
                alert.messageText = "Can't Insert Image"
                alert.informativeText = "Save the document before inserting images."
                alert.alertStyle = .warning
                alert.runModal()
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

#endif
