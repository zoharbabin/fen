#if os(macOS)
    import AppKit

    /// Draws source-line numbers alongside the editor (issue #21), reusing
    /// `NSScrollView`'s standard ruler-view mechanism (the same one Xcode's own gutter uses)
    /// instead of a custom overlay subview. Only ever attached as `NSScrollView.verticalRulerView`
    /// by `MarkdownTextView.makeNSView`/`updateNSView`; never constructed standalone.
    final class EditorGutterRulerView: NSRulerView {
        weak var textView: MarkdownNSTextView?
        /// Supplied by the owning Coordinator (issue #21 rule 1.1) so this view never computes
        /// or caches line-start offsets itself -- it only draws whatever the Coordinator already
        /// rebuilt on the last text change.
        var lineStartOffsetsProvider: (() -> [Int])?

        init(textView: MarkdownNSTextView) {
            self.textView = textView
            super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
            clientView = textView
            // AppKit's own ruler-content compositing (an internal helper view sized to the full
            // document height, not just the visible viewport) doesn't respect this view's frame
            // on its own -- `draw(_:)` is already auto-clipped to bounds, but that internal
            // compositing isn't, which let line numbers visually escape into the toolbar above
            // the editor at certain scroll positions. Backing this view with a layer and clipping
            // that layer to its bounds constrains AppKit's compositing too, not just our own draws.
            wantsLayer = true
            layer?.masksToBounds = true
            updateThickness()
        }

        @available(*, unavailable)
        required init(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Recomputes `ruleThickness` from the widest label the current document/font could draw
        /// (issue #21 zoom regression): a fixed thickness sized for the default font size fits the
        /// default-size numbers fine, but zooming in grows `numberFont` (below, `pointSize * 0.85`)
        /// right along with the editor's own font -- past the point where a 2-3 digit number still
        /// fits inside a hardcoded column, `drawHashMarksAndLabels`'s `x: ruleThickness - size.width
        /// - 6` goes negative and the number draws clipped past the ruler's own left edge. Zooming
        /// out only ever shrinks the numbers further, so a fixed thickness sized for the smallest
        /// font never shows the bug -- exactly why it was invisible until someone zoomed in. Call
        /// whenever the font or the document's line count changes, not on every draw: mutating
        /// `ruleThickness` triggers `NSScrollView` to relayout, so doing it from inside
        /// `drawHashMarksAndLabels` itself would recurse.
        func updateThickness() {
            guard let textView else { return }
            let font = textView.font ?? .systemFont(ofSize: 13)
            let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
            let lineCount = lineStartOffsetsProvider?().count ?? 0
            let digits = max(1, String(lineCount).count)
            let widestLabel = String(repeating: "9", count: digits)
            let labelWidth = widestLabel.size(withAttributes: [.font: numberFont]).width
            ruleThickness = max(24, ceil(labelWidth) + 12)
        }

        /// Scoped to the visible line fragments only (issue #21 rule 4.3): asks the layout
        /// manager only for the glyph range actually on screen, never iterating every line
        /// fragment in the document.
        override func drawHashMarksAndLabels(in _: NSRect) {
            guard let textView, let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView = textView.enclosingScrollView,
                  let lineStartOffsetsProvider else { return }
            let lineStartOffsets = lineStartOffsetsProvider()
            guard !lineStartOffsets.isEmpty else { return }

            let visibleRect = scrollView.contentView.bounds
            let fragments = visibleGutterLineFragments(
                layoutManager: layoutManager,
                textContainer: textContainer,
                visibleRect: visibleRect,
                lineStartOffsets: lineStartOffsets
            )

            let font = textView.font ?? .systemFont(ofSize: 13)
            let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
            let textColor = NSColor.secondaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: textColor]
            let insetTop = textView.textContainerInset.height

            for fragment in fragments {
                let label = "\(fragment.sourceLine)"
                let size = label.size(withAttributes: attributes)
                let convertedTop = textView.convert(
                    NSPoint(x: 0, y: fragment.rect.origin.y + insetTop), to: nil
                )
                let selfPoint = convert(convertedTop, from: nil)
                let drawRect = NSRect(
                    x: ruleThickness - size.width - 6,
                    y: selfPoint.y + (fragment.rect.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                label.draw(in: drawRect, withAttributes: attributes)
            }
        }
    }
#endif
