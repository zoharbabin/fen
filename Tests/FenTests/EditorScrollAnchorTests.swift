@testable import FenCore
import Foundation
import Testing

/// Verifies the editor-side anchor table that corrects for word wrap: a long
/// paragraph wraps into many visual lines in `MarkdownTextView`, so a naive
/// `lineIndex / totalLines` fraction drifts from where that line actually sits
/// once laid out. `computeEditorLineAnchors`/`interpolateEditorAnchor` are the
/// same piecewise-linear-interpolation technique `scroll-sync.js` uses on the
/// preview side, applied to `NSLayoutManager` line-fragment geometry instead of
/// DOM measurements — see `ScrollSyncVerifyTest.swift` for the preview-side
/// counterpart.
@Suite("Editor scroll anchor mapping")
struct EditorScrollAnchorTests {
    private struct WrappedDocument {
        let text: String
        let lineTop: (Int) -> CGFloat?
        let totalHeight: CGFloat
        let visibleHeight: CGFloat
        var maxScroll: CGFloat {
            totalHeight - visibleHeight
        }
    }

    /// Simulates a document whose first source line wraps into 20 visual lines
    /// (a long paragraph) followed by 40 short, unwrapped lines — the same
    /// "uneven density" shape `ScrollSyncVerifyTest`'s `unevenDensityDocument()`
    /// uses for the preview side, translated to editor line-fragment geometry.
    ///
    /// `visibleHeight` is a substantial fraction of `totalHeight` (not
    /// negligible), matching a real editor pane — pixel fractions built or read
    /// against `totalHeight` instead of `totalHeight - visibleHeight` disagree
    /// noticeably under that condition, which is exactly the bug this file's
    /// tests must catch.
    private static func unevenlyWrappedDocument() -> WrappedDocument {
        let wrappedVisualLines = 20
        let shortLineCount = 40
        let lineHeight: CGFloat = 20
        let totalHeight = CGFloat(wrappedVisualLines + shortLineCount) * lineHeight
        let visibleHeight = totalHeight * 0.3

        var lines = ["long wrapped paragraph"]
        for i in 1 ... shortLineCount {
            lines.append("short \(i)")
        }
        let text = lines.joined(separator: "\n")

        let lineTop: (Int) -> CGFloat? = { targetIndex in
            var charIndex = 0
            for (i, line) in lines.enumerated() {
                if charIndex == targetIndex {
                    if i == 0 {
                        return 0
                    }
                    return CGFloat(wrappedVisualLines + (i - 1)) * lineHeight
                }
                charIndex += line.utf16.count + 1
            }
            return nil
        }

        return WrappedDocument(text: text, lineTop: lineTop, totalHeight: totalHeight, visibleHeight: visibleHeight)
    }

    @Test("A naive line-count fraction diverges from the actual laid-out pixel position")
    @MainActor
    func naiveFractionDivergesFromLayout() throws {
        let doc = Self.unevenlyWrappedDocument()
        let totalLines = doc.text.components(separatedBy: "\n").count

        let targetLine = 20
        let charIndex = doc.text.components(separatedBy: "\n")[0 ..< targetLine]
            .reduce(0) { $0 + $1.utf16.count + 1 }
        let actualTop = try #require(doc.lineTop(charIndex))
        let actualPixelFraction = actualTop / doc.maxScroll
        let naiveSourceFraction = CGFloat(targetLine) / CGFloat(totalLines)

        #expect(
            abs(naiveSourceFraction - actualPixelFraction) > 0.1,
            """
            Expected the wrapped first paragraph to make the naive line-count fraction \
            (\(naiveSourceFraction)) diverge from the actual pixel fraction (\(actualPixelFraction)) — \
            otherwise this document doesn't exercise word-wrap correction
            """
        )
    }

    @Test("Anchor table recovers a line's actual pixel fraction from its naive source fraction")
    @MainActor
    func anchorTableRecoversPixelFraction() throws {
        let doc = Self.unevenlyWrappedDocument()
        let totalLines = doc.text.components(separatedBy: "\n").count
        let anchors = computeEditorLineAnchors(
            text: doc.text,
            totalHeight: doc.totalHeight,
            visibleHeight: doc.visibleHeight,
            lineTopForCharacterIndex: doc.lineTop
        )

        let targetLine = 20
        let charIndex = doc.text.components(separatedBy: "\n")[0 ..< targetLine]
            .reduce(0) { $0 + $1.utf16.count + 1 }
        let actualTop = try #require(doc.lineTop(charIndex))
        let actualPixelFraction = actualTop / doc.maxScroll
        let naiveSourceFraction = CGFloat(targetLine) / CGFloat(totalLines)

        let mapped = interpolateEditorAnchor(anchors, from: \.source, to: \.rendered, value: naiveSourceFraction)

        #expect(
            abs(mapped - actualPixelFraction) < 0.01,
            """
            Expected mapping the naive source fraction through the anchor table to recover the \
            line's actual pixel fraction (got \(mapped), wanted ~\(actualPixelFraction))
            """
        )
    }

    @Test("Pixel-to-source and source-to-pixel mappings round-trip")
    @MainActor
    func mappingsRoundTrip() {
        let doc = Self.unevenlyWrappedDocument()
        let anchors = computeEditorLineAnchors(
            text: doc.text,
            totalHeight: doc.totalHeight,
            visibleHeight: doc.visibleHeight,
            lineTopForCharacterIndex: doc.lineTop
        )

        let pixelFraction = interpolateEditorAnchor(anchors, from: \.source, to: \.rendered, value: 0.5)
        let roundTripped = interpolateEditorAnchor(anchors, from: \.rendered, to: \.source, value: pixelFraction)

        #expect(
            abs(roundTripped - 0.5) < 0.01,
            "Expected round-tripping 0.5 through both mappings to return ~0.5, got \(roundTripped)"
        )
    }

    @Test("Falls back to identity mapping for a document with too few lines to sample")
    @MainActor
    func identityFallbackForShortDocument() {
        let anchors = computeEditorLineAnchors(text: "one line", totalHeight: 20, visibleHeight: 5) { _ in 0 }
        let mapped = interpolateEditorAnchor(anchors, from: \.source, to: \.rendered, value: 0.5)
        #expect(mapped == 0.5, "Expected identity fallback with no meaningful anchors to build")
    }
}
