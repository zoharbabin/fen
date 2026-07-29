#if !os(macOS)
    import UIKit

    /// Draws source-line numbers alongside the editor on iOS (issue #21) -- the iOS mirror of
    /// `EditorGutterRulerView`. `UITextView` has no `NSRulerView` equivalent, so this is a plain
    /// `UIView` added as a subview of the text view itself; since a `UITextView` is a
    /// `UIScrollView`, a subview's frame lives in *content* coordinates, so the owning
    /// Coordinator repositions this view's `frame.origin` to the current `contentOffset` on
    /// every scroll (see `MarkdownTextView.Coordinator.repositionGutterView`) to keep it pinned
    /// to the visible left edge instead of scrolling away with the text.
    final class EditorGutterView: UIView {
        weak var textView: UITextView?
        /// Supplied by the owning Coordinator (issue #21 rule 1.1) -- this view never computes
        /// or caches line-start offsets itself.
        var lineStartOffsetsProvider: (() -> [Int])?

        /// Recomputed by `updateWidth()`; never a fixed constant (issue #21 zoom regression --
        /// see `EditorGutterRulerView.updateThickness()`'s doc comment for the macOS mirror of
        /// this same bug). Defaults to a reasonable pre-layout value so the very first frame,
        /// before `updateWidth()` has run, doesn't draw a zero-width gutter.
        private(set) var width: CGFloat = 32

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Recomputes `width` from the widest label the current document/font could draw
        /// (issue #21 zoom regression): a fixed width sized for the default font fits the
        /// default-size numbers fine, but zooming in grows `numberFont` (below, `pointSize *
        /// 0.85`) right along with the editor's own font -- past the point where a 2-3 digit
        /// number still fits inside a hardcoded column, `draw(_:)`'s `x: width - size.width - 6`
        /// goes negative and the number draws clipped past the gutter's own left edge. Call
        /// whenever the font or the document's line count changes.
        func updateWidth() {
            let font = textView?.font ?? .systemFont(ofSize: 14)
            let numberFont = UIFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
            let lineCount = lineStartOffsetsProvider?().count ?? 0
            let digits = max(1, String(lineCount).count)
            let widestLabel = String(repeating: "9", count: digits)
            let labelWidth = widestLabel.size(withAttributes: [.font: numberFont]).width
            width = max(24, ceil(labelWidth) + 12)
        }

        /// Scoped to the visible line fragments only (issue #21 rule 4.3): only asks the layout
        /// manager for the glyph range covering `rect` (this view's own visible bounds), never
        /// iterating every line fragment in the document.
        override func draw(_ rect: CGRect) {
            guard let textView, let lineStartOffsetsProvider else { return }
            let lineStartOffsets = lineStartOffsetsProvider()
            guard !lineStartOffsets.isEmpty else { return }

            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            let visibleRect = CGRect(origin: .zero, size: rect.size).offsetBy(
                dx: textView.contentOffset.x, dy: textView.contentOffset.y
            )
            let fragments = visibleGutterLineFragments(
                layoutManager: layoutManager,
                textContainer: textContainer,
                visibleRect: visibleRect,
                lineStartOffsets: lineStartOffsets
            )

            let font = textView.font ?? .systemFont(ofSize: 14)
            let numberFont = UIFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
            let textColor = UIColor.secondaryLabel
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: textColor]
            let insetTop = textView.textContainerInset.top
            let contentOriginY = textView.contentOffset.y

            for fragment in fragments {
                let label = "\(fragment.sourceLine)"
                let size = label.size(withAttributes: attributes)
                let top = fragment.rect.origin.y + insetTop - contentOriginY
                let drawRect = CGRect(
                    x: width - size.width - 6,
                    y: top + (fragment.rect.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                label.draw(in: drawRect, withAttributes: attributes)
            }
        }
    }
#endif
