#if os(macOS)
    import AppKit

    /// Editor gutter line-numbering (issue #21) Coordinator methods, split out of
    /// `MarkdownTextView.swift` to keep that file under the project's file-length lint limit.
    extension MarkdownTextView.Coordinator {
        /// Installs `EditorGutterRulerView` as `scrollView`'s vertical ruler, wiring its
        /// line-start-offsets provider back to this Coordinator's own cached table (issue #21
        /// rule 1.1) -- called once from `makeNSView`, never re-installed on every update.
        @MainActor func installGutterRulerView(
            on scrollView: NSScrollView,
            textView: MarkdownNSTextView,
            showing: Bool
        ) {
            let rulerView = EditorGutterRulerView(textView: textView)
            rulerView.lineStartOffsetsProvider = { [weak self] in self?.gutterLineStartOffsets ?? [] }
            gutterRulerView = rulerView
            scrollView.verticalRulerView = rulerView
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = showing
            // The initializer's own updateThickness() ran before lineStartOffsetsProvider was
            // wired up just above, so it sized against zero lines -- redo it now that the
            // provider can actually report the document's real line count.
            rulerView.updateThickness()
        }

        /// Rebuilds `gutterLineStartOffsets` only when the text actually changed since the
        /// last build (issue #21 rule 4.2) -- mirrors `refreshAnchorsIfNeeded`'s own
        /// staleness gate -- then marks the ruler view for redraw so it picks up the new
        /// table on its next (viewport-scoped, rule 4.3) draw pass.
        @MainActor func refreshGutterLineStartOffsetsIfNeeded(text: String) {
            guard text != gutterText else { return }
            gutterText = text
            gutterLineStartOffsets = computeLineStartOffsets(text: text)
            gutterRulerView?.updateThickness()
            gutterRulerView?.needsDisplay = true
        }
    }
#endif
