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

        static let width: CGFloat = 32

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
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
                    x: Self.width - size.width - 6,
                    y: top + (fragment.rect.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                label.draw(in: drawRect, withAttributes: attributes)
            }
        }
    }
#endif
