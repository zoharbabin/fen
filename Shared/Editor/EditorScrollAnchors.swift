import Foundation
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// A point in the piecewise-linear table mapping "fraction through the source by
/// raw line count" to "fraction through the editor's actual laid-out pixel height."
/// Corrects for word wrap the same way `scroll-sync.js` corrects for uneven block
/// density in the rendered preview: a source line that wraps into several visual
/// lines takes more vertical space than a short one, so a naive
/// `lineIndex / totalLines` fraction drifts from where that line actually sits
/// once laid out.
struct EditorLineAnchor {
    let source: CGFloat
    let rendered: CGFloat
}

/// Samples lines via `lineTopForCharacterIndex` (wired by the caller to its
/// platform's `NSLayoutManager`) to build the anchor table.
///
/// Samples at `breakpoints` -- 1-based raw source lines (issue #113) -- rather than a fixed
/// line stride. `breakpoints` is `MarkdownRenderer.RenderResult.blockStartLines` (adjusted back
/// to raw-source line numbers by the caller), the exact same `data-sourcepos` block-start lines
/// `scroll-sync.js`'s `computeAnchors()` samples on the preview side. Sampling both panes' anchor
/// tables from the same breakpoint set is what makes their interpolated values agree by
/// construction instead of by two independently-chosen sampling strategies coincidentally landing
/// close together -- the root cause of the residual couple-line drift this fixes. An out-of-range
/// or unresolvable breakpoint (a line beyond the document's line count, or one
/// `lineTopForCharacterIndex` can't resolve) is skipped rather than crashing, and an empty
/// `breakpoints` list still produces the safe two-point `[(0,0),(1,1)]` table below.
///
/// `rendered` is normalized against the *scrollable range* (`totalHeight - visibleHeight`),
/// matching how live scroll position is read and written in `scrollViewDidScroll`/
/// `applyScrollFraction` (`origin.y / (totalHeight - visibleHeight)`) — the same
/// convention `scroll-sync.js` uses for the preview side (`top / maxScroll`). Normalizing
/// against `totalHeight` instead, as an earlier version of this function did, disagreed with
/// that convention by exactly `visibleHeight / totalHeight`: scrolling to the physical bottom
/// of the editor (`origin.y == totalHeight - visibleHeight`, a live fraction of 1.0) mapped
/// through a `top / totalHeight` table to something less than 1.0, since the last line's
/// `top` never reaches `totalHeight` itself — under-reporting the source fraction on every
/// scroll and worsening the further `visibleHeight` is from negligible relative to
/// `totalHeight` (i.e. on any real, non-tiny editor pane).
@MainActor
func computeEditorLineAnchors(
    text: String,
    totalHeight: CGFloat,
    visibleHeight: CGFloat,
    breakpoints: [Int],
    lineTopForCharacterIndex: (Int) -> CGFloat?
) -> [EditorLineAnchor] {
    let maxScroll = totalHeight - visibleHeight
    guard maxScroll > 0 else { return [] }
    let lineStartOffsets = computeLineStartOffsets(text: text)
    let totalLines = lineStartOffsets.count
    guard totalLines > 1 else { return [] }

    var anchors = [EditorLineAnchor(source: 0, rendered: 0)]
    for line in breakpoints {
        guard line >= 1, line <= totalLines else { continue }
        let charIndex = lineStartOffsets[line - 1]
        guard let top = lineTopForCharacterIndex(charIndex) else { continue }
        let renderedFraction = max(0, min(1, top / maxScroll))
        let sourceFraction = CGFloat(line - 1) / CGFloat(totalLines)
        if let last = anchors.last, sourceFraction > last.source, renderedFraction > last.rendered {
            anchors.append(EditorLineAnchor(source: sourceFraction, rendered: renderedFraction))
        }
    }
    anchors.append(EditorLineAnchor(source: 1, rendered: 1))
    return anchors
}

/// One raw source line's starting character index (issue #21). Line `i` (0-based) in this
/// array starts at `offsets[i]`; the 1-based source line number for any character index is
/// `1 + ` the count of offsets not exceeding it. Built once per text change and cached by the
/// caller (mirroring `EditorLineAnchor`'s own text/height staleness gate) so gutter numbering
/// never rescans the whole document on every scroll or redraw (rule 4.2).
func computeLineStartOffsets(text: String) -> [Int] {
    var offsets = [0]
    var index = 0
    for scalar in text.utf16 {
        index += 1
        if scalar == 10 { // "\n"
            offsets.append(index)
        }
    }
    return offsets
}

/// The 1-based source line number containing `characterIndex`, via binary search over
/// `computeLineStartOffsets(text:)`'s output — O(log n), safe to call once per visible line
/// fragment on every scroll/redraw without rescanning the document (rule 4.2/4.3).
func sourceLine(forCharacterIndex characterIndex: Int, lineStartOffsets: [Int]) -> Int {
    guard !lineStartOffsets.isEmpty else { return 1 }
    var low = 0
    var high = lineStartOffsets.count - 1
    while low < high {
        let mid = (low + high + 1) / 2
        if lineStartOffsets[mid] <= characterIndex {
            low = mid
        } else {
            high = mid - 1
        }
    }
    return low + 1
}

/// One visible line fragment's source-line number and laid-out rect, in `textContainer`'s own
/// coordinate space (issue #21). The gutter's drawing code (`EditorGutterRulerView`,
/// `EditorGutterView_iOS`) only converts this rect into its own view's coordinates and draws the
/// number -- this function does the actual layout-manager walk, so it's the one place both
/// platforms' visible-range scoping (rule 4.3) and one-number-per-source-line deduplication
/// (rule 3.3) live and can be tested against real `NSLayoutManager` geometry.
struct EditorGutterLineFragment {
    let sourceLine: Int
    let rect: CGRect
}

/// Scoped to `visibleRect` only (rule 4.3): asks `layoutManager` for the glyph range covering
/// it, never iterating every line fragment in the document. Returns one `EditorGutterLineFragment`
/// per source line that starts a new visible line fragment, skipping every later wrapped visual
/// line of the same source line (rule 3.3's "a wrapped source line shows its number once").
func visibleGutterLineFragments(
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer,
    visibleRect: CGRect,
    lineStartOffsets: [Int]
) -> [EditorGutterLineFragment] {
    guard !lineStartOffsets.isEmpty else { return [] }
    let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)

    var fragments: [EditorGutterLineFragment] = []
    var glyphIndex = visibleGlyphRange.location
    var lastSourceLine: Int?
    while glyphIndex < NSMaxRange(visibleGlyphRange) {
        var effectiveRange = NSRange(location: 0, length: 0)
        let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let currentSourceLine = sourceLine(forCharacterIndex: characterIndex, lineStartOffsets: lineStartOffsets)

        if currentSourceLine != lastSourceLine {
            lastSourceLine = currentSourceLine
            fragments.append(EditorGutterLineFragment(sourceLine: currentSourceLine, rect: fragmentRect))
        }

        glyphIndex = NSMaxRange(effectiveRange)
        if effectiveRange.length == 0 {
            break
        }
    }
    return fragments
}

/// The same piecewise-linear-interpolation-with-clamped-endpoints technique as
/// `scroll-sync.js`'s `interpolate(table, fromKey, toKey, value)` — kept in sync
/// deliberately; `Tests/FenTests/CrossLanguageInterpolationTest.swift` runs both
/// implementations against the same table and inputs to prove they agree.
func interpolateEditorAnchor(
    _ table: [EditorLineAnchor],
    from: (EditorLineAnchor) -> CGFloat,
    to: (EditorLineAnchor) -> CGFloat,
    value: CGFloat
) -> CGFloat {
    guard table.count >= 2, let first = table.first, let last = table.last else { return value }
    if value <= from(first) {
        return to(first)
    }
    if value >= from(last) {
        return to(last)
    }
    for i in 1 ..< table.count {
        let current = table[i]
        if value <= from(current) {
            let previous = table[i - 1]
            let span = from(current) - from(previous)
            let progress = span > 0 ? (value - from(previous)) / span : 0
            return to(previous) + progress * (to(current) - to(previous))
        }
    }
    return value
}
