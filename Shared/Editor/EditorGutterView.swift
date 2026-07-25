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
            ruleThickness = 40
        }

        @available(*, unavailable)
        required init(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
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
