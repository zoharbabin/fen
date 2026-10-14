#if !os(macOS)
    import UIKit

    /// Per-line styling for Live Preview: which block a line is in and which spans to apply, split out of
    /// `MarkdownTextView+LivePreview_iOS.swift` to keep that file under the file-length limit.
    extension MarkdownTextView.Coordinator {
        /// Styles one inactive line by what block it is in: a table line is styled cell by cell, a plain line
        /// gets rule, list, footnote and inline styling, and front matter and code are left alone.
        @MainActor func styleInactiveLine(
            _ kind: LivePreviewBlockContext.Kind,
            fullRange: NSRange,
            ordinal: Int? = nil,
            in ns: NSString,
            textView: MarkdownTextView.MarkdownUITextView,
            pendingOverlaySpans: inout [LivePreviewEditing.Span]
        ) {
            let textStorage = textView.textStorage
            let contentRange = strippingTrailingNewline(fullRange, in: ns)
            let line = ns.substring(with: contentRange)
            let background: PlatformColor = textView.backgroundColor ?? .systemBackground
            switch kind {
            case .skipped, .code:
                return
            case let .table(role):
                let cells = LivePreviewBlockStyle.applyTable(
                    role,
                    line: line,
                    fullRange: fullRange,
                    storage: textStorage,
                    background: background
                )
                for cell in cells where cell.length > 0 {
                    styleInline(
                        ns.substring(with: cell),
                        contentStart: cell.location,
                        textStorage: textStorage,
                        textView: textView,
                        pendingOverlaySpans: &pendingOverlaySpans
                    )
                }
            case .text:
                let previous = contentRange.location > 0
                    ? ns.substring(with: strippingTrailingNewline(
                        ns.lineRange(for: NSRange(location: contentRange.location - 1, length: 0)), in: ns
                    ))
                    : nil
                let isRule = LivePreviewBlockStyle.apply(
                    line: line,
                    lineStart: contentRange.location,
                    previousLine: previous,
                    ordinal: ordinal,
                    storage: textStorage,
                    background: background
                )
                if !isRule {
                    styleLine(
                        line,
                        lineStart: contentRange.location,
                        textStorage: textStorage,
                        textView: textView,
                        pendingOverlaySpans: &pendingOverlaySpans
                    )
                }
            }
        }

        /// Draws `block` as its rendered picture when one is ready, and returns `true`. Returns `false` when the
        /// lines need ordinary styling: its source is being edited, or no picture of it exists yet. A missing
        /// picture is requested, and the document restyles when it arrives. Until then an older picture of the
        /// same block, from another width, stands in.
        @MainActor func styleRenderedBlock(
            _ block: RenderedBlock, activeRange: NSRange, in ns: NSString,
            textView: MarkdownTextView.MarkdownUITextView
        ) -> Bool {
            let container = textView.textContainer
            guard !LivePreviewBlockStyle.isEditing(
                block, active: activeRange, selection: textView.selectedRange, in: ns
            ) else { return false }
            let background: PlatformColor = textView.backgroundColor ?? .systemBackground
            let column = container.size.width - 2 * container.lineFragmentPadding
            guard let key = LivePreviewSnapshots.key(for: block, columnWidth: column, background: background)
            else { return false }
            let snapshots = LivePreviewSnapshots.shared
            let image: PlatformImage
            if let cached = snapshots.image(for: key) {
                image = cached
            } else {
                snapshots.request(key, owner: self) { [weak self] in self?.livePreviewSnapshotReady() }
                // The last picture of this block stands in while the new one renders.
                guard let standIn = snapshots.standIn(for: key) else { return false }
                image = standIn.image
            }
            LivePreviewBlockStyle.applyRendered(
                image, block: block.range, storage: textView.textStorage, background: background, column: column
            )
            return true
        }

        /// Notes the picture width this styling was made for, and restyles when a resize changes it, so pictures
        /// are drawn again at the new width.
        @MainActor func watchLivePreviewWidth(of textView: MarkdownTextView.MarkdownUITextView) {
            watchLivePreviewSettings(of: textView)
            textView.livePreviewPictureWidth = Self.pictureWidth(of: textView)
            guard textView.onLayout == nil else { return }
            textView.onLayout = { [weak self, weak textView] in
                guard let self, let textView, parent.isLivePreviewEnabled,
                      textView.livePreviewPictureWidth != Self.pictureWidth(of: textView) else { return }
                applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
            }
        }

        private static func pictureWidth(of textView: UITextView) -> Int {
            let container = textView.textContainer
            return LivePreviewSnapshots
                .pictureWidth(forColumn: container.size.width - 2 * container.lineFragmentPadding)
        }

        /// Draws the note again when a preview setting that changes a picture changes.
        @MainActor private func watchLivePreviewSettings(of textView: MarkdownTextView.MarkdownUITextView) {
            guard !textView.isWatchingLivePreviewSettings else { return }
            textView.isWatchingLivePreviewSettings = true
            LivePreviewSettingsWatch.watch { [weak self, weak textView] in
                guard let self, let textView, parent.isLivePreviewEnabled else {
                    textView?.isWatchingLivePreviewSettings = false
                    return false
                }
                applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
                return true
            }
        }

        /// Shows a formula as its picture when one is ready. The source stays as it is until then, and for a
        /// formula that fails to render.
        @MainActor func styleInlineMath(
            _ span: LivePreviewEditing.Span, source: String, textStorage: NSTextStorage, background: PlatformColor
        ) {
            guard let key = LivePreviewSnapshots.key(forFormula: source, background: background),
                  let picture = LivePreviewSnapshots.shared.resolve(
                      key, owner: self, onReady: { [weak self] in self?.livePreviewSnapshotReady() }
                  ) else { return }
            let range = NSRange(
                location: span.markerRanges[0].location,
                length: NSMaxRange(span.markerRanges[1]) - span.markerRanges[0].location
            )
            LivePreviewBlockStyle.applyInlineMath(picture, range: range, storage: textStorage, background: background)
        }

        @MainActor private func livePreviewSnapshotReady() {
            guard let textView else { return }
            applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
        }

        func strippingTrailingNewline(_ lineRange: NSRange, in ns: NSString) -> NSRange {
            var contentRange = lineRange
            guard contentRange.length > 0 else { return contentRange }
            let lastIndex = contentRange.location + contentRange.length - 1
            if ns.character(at: lastIndex) == 10 { // "\n"
                contentRange.length -= 1
            }
            if contentRange.length > 0 {
                let secondLastIndex = contentRange.location + contentRange.length - 1
                if ns.character(at: secondLastIndex) == 13 { // "\r"
                    contentRange.length -= 1
                }
            }
            return contentRange
        }

        @MainActor private func styleLine(
            _ line: String, lineStart: Int, textStorage: NSTextStorage, textView: MarkdownTextView.MarkdownUITextView,
            pendingOverlaySpans: inout [LivePreviewEditing.Span]
        ) {
            var content = line
            var contentStart = lineStart
            if let blockSpan = LivePreviewEditing.blockPrefixSpan(line: line, lineStart: lineStart) {
                applySpan(
                    blockSpan, textStorage: textStorage, textView: textView, pendingOverlaySpans: &pendingOverlaySpans
                )
                let consumed = blockSpan.contentRange.location - lineStart
                content = String(line.dropFirst(consumed))
                contentStart = blockSpan.contentRange.location
                if case .checkbox = blockSpan.kind {
                    return
                }
            }
            styleInline(
                content,
                contentStart: contentStart,
                textStorage: textStorage,
                textView: textView,
                pendingOverlaySpans: &pendingOverlaySpans
            )
        }

        /// Applies the inline spans (bold, italic, code, links and so on) found in `content`.
        @MainActor private func styleInline(
            _ content: String, contentStart: Int, textStorage: NSTextStorage,
            textView: MarkdownTextView.MarkdownUITextView,
            pendingOverlaySpans: inout [LivePreviewEditing.Span]
        ) {
            for inlineSpan in LivePreviewEditing.inlineSpans(
                in: content,
                textStart: contentStart,
                math: LivePreviewSnapshots.mathDelimiters(LivePreviewSnapshots.shared.kinds())
            ) {
                applySpan(
                    inlineSpan,
                    textStorage: textStorage,
                    textView: textView,
                    pendingOverlaySpans: &pendingOverlaySpans
                )
            }
        }
    }
#endif
