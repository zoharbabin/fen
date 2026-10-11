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
        /// lines need ordinary styling: its source is being edited, or the picture is still rendering. A missing
        /// picture is requested, and the document restyles when it arrives.
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
            guard let image = snapshots.image(for: key) else {
                snapshots.request(key, owner: self) { [weak self] in self?.livePreviewSnapshotReady() }
                return false
            }
            LivePreviewBlockStyle.applyRendered(
                image, block: block.range, storage: textView.textStorage, background: background
            )
            return true
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
            for inlineSpan in LivePreviewEditing.inlineSpans(in: content, textStart: contentStart) {
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
