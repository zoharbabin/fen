#if !os(macOS)
    import Highlightr
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

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
        /// Mirrors the macOS `MarkdownTextView.breakpoints` doc comment (issue #113).
        var breakpoints: [Int] = []
        /// Mirrors the macOS `MarkdownTextView.isFocusModeEnabled` doc comment (issue #19 rule
        /// 1.3): the toggle itself is a single app-wide `Preferences.editorFocusModeEnabled`
        /// value, but the derived dim/centering state stays on this Coordinator instance.
        var isFocusModeEnabled: Bool = false
        /// Mirrors the macOS `MarkdownTextView.isFocusModeDimsTextEnabled` doc comment (issue #127 rule 2.2).
        var isFocusModeDimsTextEnabled: Bool = true
        /// Mirrors the macOS `MarkdownTextView.isFocusModeCentersCaretEnabled` doc comment (issue #127 rule 2.3).
        var isFocusModeCentersCaretEnabled: Bool = true
        /// Mirrors the macOS `MarkdownTextView.isLivePreviewEnabled` doc comment (issue #2 rule 1.2).
        var isLivePreviewEnabled: Bool = false
        /// Mirrors the macOS `MarkdownTextView.showLineNumbers` doc comment (issue #21).
        var showLineNumbers: Bool = false
        /// The document's on-disk location, used to resolve where a pasted/dropped image's
        /// sidecar folder belongs (issue #18). `nil` for an unsaved document -- that case
        /// declines the paste/drop with an alert rather than guessing a location.
        var documentURL: URL?
        var onScroll: ((CGFloat) -> Void)?
        var onTextChange: (() -> Void)?
        /// Mirrors the macOS `MarkdownTextView.onFocusRangeChange` doc comment (issue #127 rule 3.3).
        var onFocusRangeChange: ((FocusLineRange?) -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> UITextView {
            let textStorage = CodeAttributedString()
            textStorage.language = "markdown"
            textStorage.highlightr.setTheme(to: highlightThemeName)
            textStorage.highlightr.theme.setCodeFont(font)
            // Notifies the coordinator once Highlightr's async re-highlight for a range lands,
            // so focus-mode dim attributes can be reapplied after (never before) that pass --
            // mirrors the macOS Coordinator's wiring for issue #19 rule 4.3.
            textStorage.highlightDelegate = context.coordinator

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
            textView.pasteDelegate = context.coordinator
            context.coordinator.textView = textView
            context.coordinator.documentURL = documentURL

            let gutterView = EditorGutterView()
            gutterView.textView = textView
            gutterView.lineStartOffsetsProvider = { [weak coordinator = context.coordinator] in
                coordinator?.gutterLineStartOffsets ?? []
            }
            gutterView.updateWidth()
            gutterView.isHidden = !showLineNumbers
            textView.addSubview(gutterView)
            context.coordinator.gutterView = gutterView
            textView.showsLineNumberGutter = showLineNumbers
            textView.gutterWidth = gutterView.width
            textView.applyWidthLimitedInset()

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
                widthLimitedTextView.showsLineNumberGutter = showLineNumbers
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

            let focusModeJustToggled = context.coordinator.parent.isFocusModeEnabled != isFocusModeEnabled
                || context.coordinator.parent.isFocusModeDimsTextEnabled != isFocusModeDimsTextEnabled
                || context.coordinator.parent.isFocusModeCentersCaretEnabled != isFocusModeCentersCaretEnabled
            let livePreviewJustToggled = context.coordinator.parent.isLivePreviewEnabled != isLivePreviewEnabled
            context.coordinator.parent = self
            context.coordinator.documentURL = documentURL
            if isScrollSyncEnabled {
                context.coordinator.applyScrollFraction(scrollFraction, to: textView)
            }
            // Toggling the Preferences-backed switch itself doesn't fire textViewDidChange or a
            // selection-change notification, so it needs its own trigger here -- both to dim the
            // initial active paragraph on enable and to fully clear dimming on disable (rule 3.5).
            if focusModeJustToggled {
                context.coordinator.applyFocusModeIfNeeded(in: textView)
            }
            if livePreviewJustToggled {
                context.coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
            }

            context.coordinator.gutterView?.isHidden = !showLineNumbers
            context.coordinator.refreshGutterLineStartOffsetsIfNeeded(text: textView.text)
            syncGutterWidth(textView, context: context, fontJustChanged: needsFullRehighlight)
        }

        /// Keeps the gutter subview's frame and the text container's left inset matched to its
        /// current `EditorGutterView.width` (issue #21 zoom regression, mirrors the macOS fix in
        /// `MarkdownTextView.swift`'s `updateNSView`). `refreshGutterLineStartOffsetsIfNeeded`'s
        /// own `updateWidth()` call only fires on a text change, so a pure zoom step (font
        /// changes, text doesn't) needs `fontJustChanged` as a separate trigger or the gutter
        /// keeps its stale pre-zoom width.
        private func syncGutterWidth(_ textView: UITextView, context: Context, fontJustChanged: Bool) {
            guard let gutterView = context.coordinator.gutterView else { return }
            if fontJustChanged {
                gutterView.updateWidth()
            }
            if let widthLimitedTextView = textView as? MarkdownUITextView,
               widthLimitedTextView.gutterWidth != gutterView.width {
                widthLimitedTextView.gutterWidth = gutterView.width
                widthLimitedTextView.applyWidthLimitedInset()
            }
            gutterView.frame = CGRect(
                x: textView.contentOffset.x, y: 0, width: gutterView.width, height: textView.contentSize.height
            )
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
            /// Reserves room on the left for `EditorGutterView` (issue #21) -- toggling this
            /// re-runs `applyWidthLimitedInset()` so the text container narrows/widens to make
            /// room without moving the gutter's own dynamically-sized column.
            var showsLineNumberGutter = false {
                didSet { applyWidthLimitedInset() }
            }

            /// Set by `updateUIView`/the Coordinator once `EditorGutterView.updateWidth()` has
            /// run against the current font/line-count, so this inset always matches the gutter's
            /// actual on-screen width (issue #21 zoom regression) instead of a stale constant.
            var gutterWidth: CGFloat = 32

            func applyWidthLimitedInset() {
                let inset = MarkdownTextEditing.widthLimitedHorizontalInset(
                    viewWidth: bounds.width,
                    baseInset: baseHorizontalInset,
                    isWidthLimited: isWidthLimited,
                    maximumWidth: maximumWidth
                )
                let leftInset = showsLineNumberGutter ? inset + gutterWidth : inset
                textContainerInset = UIEdgeInsets(
                    top: verticalInset, left: leftInset, bottom: verticalInset, right: inset
                )
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                if isWidthLimited {
                    applyWidthLimitedInset()
                }
            }

            /// The caret's bounding rect at `location`, in this text view's own coordinate
            /// space -- used to position the slash-command menu popup (issue #1).
            /// `UITextView.caretRect(for:)` already returns bounds-space coordinates, unlike
            /// AppKit's screen-space `firstRect(forCharacterRange:)`, so no further conversion
            /// is needed here.
            func caretRect(forCharacterIndex location: Int) -> CGRect? {
                guard let position = position(from: beginningOfDocument, offset: location) else { return nil }
                return caretRect(for: position)
            }

            /// `range`'s bounding rect, in this text view's own coordinate space -- used to
            /// position live-preview's checkbox/image overlays (issue #2) over the markdown
            /// range they replace.
            func rect(forCharacterRange range: NSRange) -> CGRect? {
                guard let start = position(from: beginningOfDocument, offset: range.location),
                      let end = position(from: start, offset: range.length),
                      let textRange = textRange(from: start, to: end) else { return nil }
                return firstRect(for: textRange)
            }
        }

        // `HighlightDelegate` is a nonisolated, unannotated Objective-C protocol, but
        // `CodeAttributedString.highlight(_:)` only ever calls it from `DispatchQueue.main.async`
        // (confirmed by reading `Dependency/Highlightr/src/classes/CodeAttributedString.swift`), so
        // `@preconcurrency` documents that real, already-main-thread guarantee instead of papering
        // over an actual race.
        class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate, @preconcurrency HighlightDelegate {
            var parent: MarkdownTextView
            weak var textView: UITextView?
            var themeName: String
            /// The document's on-disk location (issue #18); see `MarkdownTextView.documentURL`'s
            /// doc comment. Kept on the Coordinator (not read from `parent` at paste time) since
            /// `textPasteConfigurationSupporting(_:transform:)`'s completion can fire
            /// after `updateUIView` has already run again with a new `parent`.
            var documentURL: URL?
            private var isApplyingExternalScroll = false
            private var lastAppliedScrollFraction: CGFloat?
            private var lastAppliedContentHeight: CGFloat?
            private var anchors: [EditorLineAnchor] = []
            private var anchorText: String?
            private var anchorHeight: CGFloat = 0
            private var anchorVisibleHeight: CGFloat = 0
            /// Mirrors the macOS Coordinator's `anchorBreakpoints` doc comment (issue #113).
            private var anchorBreakpoints: [Int] = []
            /// The paragraph range currently undimmed by focus mode, or `nil` when focus mode is
            /// off. Lives on this Coordinator instance only (issue #19 rule 1.1) -- never shared
            /// across two panes/windows editing the same or different documents. Not `private`
            /// since `MarkdownTextView+FocusMode_iOS.swift`'s extension needs access from another
            /// file in the module (Swift's `private` only reaches same-file extensions).
            var focusModeActiveRange: NSRange?
            /// This Coordinator's own slash-command menu state (issue #1 rule 1.1) -- constructed
            /// fresh per instance, never shared across two open documents/windows. Not `private`
            /// since `MarkdownTextView+SlashCommandMenu_iOS.swift`'s extension needs access from
            /// another file in the module.
            let slashMenuState = SlashCommandMenuState()
            /// The live popup subview showing `slashMenuState`, or `nil` while no trigger is
            /// active. Not `private` for the same cross-file reason as `slashMenuState`.
            var slashMenuHostingController: UIHostingController<SlashCommandMenuView>?
            /// This Coordinator's own line-start-offset cache for the gutter (issue #21 rule
            /// 1.1) -- mirrors the macOS Coordinator's `gutterLineStartOffsets`. Not `private`:
            /// `EditorGutterView` reads it via `lineStartOffsetsProvider`.
            var gutterLineStartOffsets: [Int] = []
            private var gutterText: String?
            /// The gutter subview added by `makeUIView`, or `nil` before that runs. Not
            /// `private`: `updateUIView` toggles its visibility/frame directly.
            weak var gutterView: EditorGutterView?
            /// Mirrors the macOS Coordinator's `focusModeDimsCurrentlyApplied` doc comment
            /// (issue #127 rule 2.2).
            var focusModeDimsCurrentlyApplied = false
            /// Mirrors the macOS Coordinator's `lastNotifiedFocusRange` doc comment (issue #127
            /// rule 3.3/4.2).
            var lastNotifiedFocusRange: FocusLineRange??
            /// Mirrors the macOS Coordinator's five live-preview (issue #2) state properties
            /// verbatim, each living on this instance only (rule 1.1) -- never shared across two
            /// open documents/windows. Not `private`: `MarkdownTextView+LivePreview_iOS.swift`'s
            /// extension needs access from another file in the module.
            var livePreviewStyledText: String?
            var livePreviewCaretParagraphRange: NSRange?
            var livePreviewImageCache: [String: PlatformImage] = [:]
            var livePreviewCheckboxOverlays: [Int: UIButton] = [:]
            var livePreviewImageOverlays: [Int: UIImageView] = [:]

            init(_ parent: MarkdownTextView) {
                self.parent = parent
                themeName = parent.highlightThemeName
                super.init()
                slashMenuState.commit = { [weak self] action in
                    self?.commitSlashCommandMenuEntry(action)
                }
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
                parent.onTextChange?()
                applyFocusModeIfNeeded(in: textView)
                recenterCaretOnActiveLine(in: textView)
                recomputeSlashMenu(in: textView)
                refreshGutterLineStartOffsetsIfNeeded(text: textView.text)
                applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
            }

            /// Rebuilds `gutterLineStartOffsets` only when the text actually changed since the
            /// last build (issue #21 rule 4.2) -- mirrors the macOS Coordinator's own gate --
            /// then marks the gutter view for redraw so it picks up the new table on its next
            /// (viewport-scoped, rule 4.3) draw pass.
            func refreshGutterLineStartOffsetsIfNeeded(text: String) {
                guard text != gutterText else { return }
                gutterText = text
                gutterLineStartOffsets = computeLineStartOffsets(text: text)
                gutterView?.updateWidth()
                gutterView?.setNeedsDisplay()
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                applyFocusModeIfNeeded(in: textView)
                recenterCaretOnActiveLine(in: textView)
                recomputeSlashMenu(in: textView)
                applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
            }

            // MARK: - Pasted/dropped image (issue #18)

            /// Handles both paste and drag-drop of an image: `UITextDropping.h` documents that a
            /// text control's own drop interaction routes dropped items through this same
            /// `pasteDelegate` to produce the resulting string, so one method covers both gestures
            /// -- no separate `UIDropInteraction`/`textDropDelegate` is needed (empirically
            /// confirmed against the iOS 26.5 SDK headers, issue #18 Phase 3).
            ///
            /// Declines (via `setDefaultResult()`, letting UIKit's own default handling proceed)
            /// for any item that isn't an image or whose bytes fail to write; on success, supplies
            /// the Markdown link as this item's string result and lets UIKit insert it at the
            /// correct location itself, rather than manipulating `textView.text` directly the way
            /// the macOS `readSelection` override does -- UIKit already owns that splice for a
            /// paste/drop dispatched through `UITextPasteItem`.
            @MainActor func textPasteConfigurationSupporting(
                _: UITextPasteConfigurationSupporting,
                transform item: UITextPasteItem
            ) {
                guard let documentURL else {
                    presentUnsavedDocumentAlert()
                    item.setDefaultResult()
                    return
                }
                let itemProvider = item.itemProvider
                guard let typeIdentifier = itemProvider.registeredTypeIdentifiers.first(where: {
                    UTType($0)?.conforms(to: .image) == true
                }), let contentType = UTType(typeIdentifier) else {
                    item.setDefaultResult()
                    return
                }

                itemProvider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    Task { @MainActor in
                        guard let data,
                              let relativePath = ImageSidecarWriter.write(
                                  data: data, contentType: contentType, documentURL: documentURL
                              ) else {
                            item.setDefaultResult()
                            return
                        }
                        let altText = (relativePath as NSString).lastPathComponent
                        let insertion = MarkdownFormatting.insertImageLink(
                            altText: altText,
                            relativePath: relativePath,
                            into: "",
                            at: NSRange(location: 0, length: 0)
                        ).text
                        item.setResult(string: insertion)
                    }
                }
            }

            @MainActor private func presentUnsavedDocumentAlert() {
                let alert = UIAlertController(
                    title: "Can't Insert Image",
                    message: "Save the document before inserting images.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)?
                    .rootViewController?
                    .present(alert, animated: true)
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
            /// diverge from where a line actually sits once laid out). `rendered` is normalized
            /// against `totalHeight - visibleHeight` (see `EditorScrollAnchors.swift`), so a
            /// pane-height-only resize (e.g. rotating the device with no split-divider move,
            /// `totalHeight` unchanged) shifts that normalization without this check noticing
            /// unless `visibleHeight` is part of the fingerprint too.
            private func refreshAnchorsIfNeeded(
                textView: UITextView, totalHeight: CGFloat, visibleHeight: CGFloat, breakpoints: [Int]
            ) {
                let text = textView.text ?? ""
                guard text != anchorText || totalHeight != anchorHeight || visibleHeight != anchorVisibleHeight
                    || breakpoints != anchorBreakpoints
                else { return }
                anchorText = text
                anchorHeight = totalHeight
                anchorVisibleHeight = visibleHeight
                anchorBreakpoints = breakpoints
                anchors = computeEditorLineAnchors(
                    text: text, totalHeight: totalHeight, visibleHeight: visibleHeight, breakpoints: breakpoints
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
                guard let textView = scrollView as? UITextView else { return }
                gutterView?.frame.origin = CGPoint(x: textView.contentOffset.x, y: 0)
                gutterView?.setNeedsDisplay()
                guard !isApplyingExternalScroll else { return }
                let contentHeight = scrollView.contentSize.height
                let visibleHeight = scrollView.bounds.height
                guard contentHeight > visibleHeight else { return }
                refreshAnchorsIfNeeded(
                    textView: textView,
                    totalHeight: contentHeight,
                    visibleHeight: visibleHeight,
                    breakpoints: parent.breakpoints
                )
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
                refreshAnchorsIfNeeded(
                    textView: textView,
                    totalHeight: contentHeight,
                    visibleHeight: visibleHeight,
                    breakpoints: parent.breakpoints
                )
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
