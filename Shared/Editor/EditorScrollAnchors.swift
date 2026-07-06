import Foundation

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
/// platform's `NSLayoutManager`) to build the anchor table. Caps the sample count
/// so pathologically long documents don't pay a cost proportional to their full
/// line count on every rebuild.
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
    lineTopForCharacterIndex: (Int) -> CGFloat?
) -> [EditorLineAnchor] {
    let maxScroll = totalHeight - visibleHeight
    guard maxScroll > 0 else { return [] }
    let lines = text.components(separatedBy: "\n")
    let totalLines = lines.count
    guard totalLines > 1 else { return [] }

    let stride = max(1, totalLines / 2000)
    var anchors = [EditorLineAnchor(source: 0, rendered: 0)]
    var charIndex = 0
    for (i, line) in lines.enumerated() {
        if i > 0, i % stride == 0, let top = lineTopForCharacterIndex(charIndex) {
            let renderedFraction = max(0, min(1, top / maxScroll))
            let sourceFraction = CGFloat(i) / CGFloat(totalLines)
            if let last = anchors.last, sourceFraction > last.source, renderedFraction > last.rendered {
                anchors.append(EditorLineAnchor(source: sourceFraction, rendered: renderedFraction))
            }
        }
        charIndex += line.utf16.count + 1
    }
    anchors.append(EditorLineAnchor(source: 1, rendered: 1))
    return anchors
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
    if value <= from(first) { return to(first) }
    if value >= from(last) { return to(last) }
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
