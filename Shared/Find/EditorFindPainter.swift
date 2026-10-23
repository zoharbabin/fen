#if os(macOS)
    import AppKit

    /// Paints Find's matches in the editor with `NSLayoutManager` temporary attributes. They sit on top of
    /// the text storage's own attributes, so syntax highlighting and Live Preview styling are untouched, and
    /// they follow the text as it changes. Only the matches near the viewport are painted.
    @MainActor
    final class EditorFindPainter {
        private(set) var ranges: [NSRange] = []
        private(set) var current: Int?
        private var paintedWindow: NSRange?

        /// Matches painted at most, so a one-letter query in a big note stays cheap.
        static let paintLimit = 5000

        private static var matchColor: NSColor {
            NSColor.systemYellow.withAlphaComponent(0.4)
        }

        private static var currentColor: NSColor {
            NSColor.systemOrange.withAlphaComponent(0.75)
        }

        var hasMatches: Bool {
            !ranges.isEmpty
        }

        func show(_ ranges: [NSRange], current: Int?, in textView: NSTextView, scroll: Bool) {
            self.ranges = ranges
            self.current = current
            paint(in: textView)
            guard scroll, let current, ranges.indices.contains(current) else { return }
            reveal(ranges[current], in: textView)
        }

        func clear(in textView: NSTextView) {
            ranges = []
            current = nil
            paintedWindow = nil
            guard let layout = textView.layoutManager, let storage = textView.textStorage else { return }
            layout.removeTemporaryAttribute(
                .backgroundColor,
                forCharacterRange: NSRange(location: 0, length: storage.length)
            )
        }

        /// Called while scrolling: repaints only when the viewport left the painted window.
        func viewportMoved(in textView: NSTextView) {
            guard !ranges.isEmpty, let window = paintedWindow else { return }
            let visible = visibleCharacters(in: textView)
            if visible.location >= window.location, NSMaxRange(visible) <= NSMaxRange(window) {
                return
            }
            paint(in: textView)
        }

        // MARK: Painting

        private func visibleCharacters(in textView: NSTextView) -> NSRange {
            guard let layout = textView.layoutManager, let container = textView.textContainer else {
                return NSRange(location: 0, length: 0)
            }
            let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
            return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }

        private func paint(in textView: NSTextView) {
            guard let layout = textView.layoutManager, let storage = textView.textStorage else { return }
            layout.removeTemporaryAttribute(
                .backgroundColor,
                forCharacterRange: NSRange(location: 0, length: storage.length)
            )
            guard !ranges.isEmpty else {
                paintedWindow = nil
                return
            }
            let visible = visibleCharacters(in: textView)
            let margin = max(visible.length, 2000)
            let low = max(0, visible.location - margin)
            let high = min(storage.length, NSMaxRange(visible) + margin)
            paintedWindow = NSRange(location: low, length: high - low)

            var index = Self.firstIndex(endingAfter: low, in: ranges)
            var painted = 0
            while index < ranges.count, ranges[index].location < high, painted < Self.paintLimit {
                let range = ranges[index]
                if NSMaxRange(range) <= storage.length, index != current {
                    layout.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: range)
                    painted += 1
                }
                index += 1
            }
            if let current, ranges.indices.contains(current), NSMaxRange(ranges[current]) <= storage.length {
                layout.addTemporaryAttribute(
                    .backgroundColor,
                    value: Self.currentColor,
                    forCharacterRange: ranges[current]
                )
            }
        }

        /// The first range whose end is past `position`. `ranges` is sorted and doesn't overlap.
        static func firstIndex(endingAfter position: Int, in ranges: [NSRange]) -> Int {
            var low = 0
            var high = ranges.count
            while low < high {
                let mid = (low + high) / 2
                if NSMaxRange(ranges[mid]) <= position {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        // MARK: Scrolling

        /// Scrolls only when `range` is off screen, and then puts it a third of the way down. The caret and the
        /// selection stay where they are.
        private func reveal(_ range: NSRange, in textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let visible = scrollView.contentView.bounds
            let margin = min(60, visible.height / 4)
            if rect.minY >= visible.minY + margin, rect.maxY <= visible.maxY - margin {
                return
            }
            let maxY = max(0, textView.frame.height - visible.height)
            let targetY = min(max(0, rect.minY - visible.height / 3), maxY)
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func pulse(in textView: NSTextView) {
            guard let current, ranges.indices.contains(current) else { return }
            textView.showFindIndicator(for: ranges[current])
        }
    }
#endif
