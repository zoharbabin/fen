import AppKit
@testable import FenCore
import Foundation
import Testing

/// Regression coverage for the issue #21 zoom-in gutter bug: `EditorGutterRulerView` used to size
/// `ruleThickness` once at init and never revisit it, so zooming the editor's font up grew the
/// number labels (`numberFont` scales with `font.pointSize`) past the fixed column width --
/// `drawHashMarksAndLabels`'s `x: ruleThickness - size.width - 6` then goes negative and the
/// number draws clipped off the ruler's own left edge. Proves `updateThickness()` keeps the
/// widest label's drawn x-origin non-negative across a realistic zoom range, not just at the
/// default font size where the bug was invisible.
@Suite("Editor gutter zoom thickness")
struct EditorGutterZoomThicknessTests {
    @MainActor
    private static func makeAttachedRuler(
        lineCount: Int,
        fontSize: CGFloat
    ) -> (MarkdownNSTextView, EditorGutterRulerView) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let textStorage = NSTextStorage(string: "line", attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)

        let textView = MarkdownNSTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            textContainer: textContainer
        )
        textView.font = font

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView

        let rulerView = EditorGutterRulerView(textView: textView)
        rulerView.lineStartOffsetsProvider = { Array(0 ..< lineCount) }
        rulerView.updateThickness()
        return (textView, rulerView)
    }

    /// The exact geometry `drawHashMarksAndLabels` uses to place a label -- reproduced here
    /// rather than calling the drawing method itself, since that method needs a real
    /// `NSLayoutManager` glyph layout pass wired to visible line fragments, which is already
    /// covered by `EditorGutterTests.swift`. This test isolates the thickness/label-width
    /// relationship the zoom bug actually broke.
    @MainActor
    private static func drawnXOrigin(
        ruler: EditorGutterRulerView,
        textView: MarkdownNSTextView,
        lineCount: Int
    ) -> CGFloat {
        let font = textView.font ?? .systemFont(ofSize: 13)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
        let widestLabel = String(lineCount)
        let labelWidth = widestLabel.size(withAttributes: [.font: numberFont]).width
        return ruler.ruleThickness - labelWidth - 6
    }

    @Test("At the default font size the widest label already fits inside the ruler column")
    @MainActor
    func defaultFontSizeLabelFitsInsideColumn() {
        let (textView, ruler) = Self.makeAttachedRuler(lineCount: 999, fontSize: 14)
        #expect(Self.drawnXOrigin(ruler: ruler, textView: textView, lineCount: 999) >= 0)
    }

    @Test("Zooming in grows ruleThickness so the widest label's drawn x-origin stays non-negative")
    @MainActor
    func zoomingInKeepsLabelInsideColumn() {
        let (textView, ruler) = Self.makeAttachedRuler(lineCount: 999, fontSize: 14)
        let thicknessBefore = ruler.ruleThickness

        for zoomedSize: CGFloat in [24, 36, 48] {
            textView.font = NSFont.monospacedSystemFont(ofSize: zoomedSize, weight: .regular)
            ruler.updateThickness()
            let xOrigin = Self.drawnXOrigin(ruler: ruler, textView: textView, lineCount: 999)
            #expect(
                xOrigin >= 0,
                "Expected label to stay inside the ruler column at font size \(zoomedSize), got x-origin \(xOrigin)"
            )
        }

        #expect(
            ruler.ruleThickness > thicknessBefore,
            "Expected ruleThickness to grow once the font zoomed in past the default size"
        )
    }

    @Test("Zooming back out shrinks ruleThickness again, matching the smaller font's label width")
    @MainActor
    func zoomingOutShrinksThicknessBackDown() {
        let (textView, ruler) = Self.makeAttachedRuler(lineCount: 999, fontSize: 48)
        let thicknessZoomedIn = ruler.ruleThickness

        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ruler.updateThickness()

        #expect(ruler.ruleThickness < thicknessZoomedIn)
        #expect(Self.drawnXOrigin(ruler: ruler, textView: textView, lineCount: 999) >= 0)
    }

    @Test("A larger document with more digits widens the ruler even at a fixed font size")
    @MainActor
    func moreDigitsWidensRulerAtFixedFontSize() {
        let (textViewSmall, rulerSmall) = Self.makeAttachedRuler(lineCount: 9, fontSize: 14)
        let (textViewLarge, rulerLarge) = Self.makeAttachedRuler(lineCount: 12345, fontSize: 14)

        #expect(rulerLarge.ruleThickness > rulerSmall.ruleThickness)
        #expect(Self.drawnXOrigin(ruler: rulerSmall, textView: textViewSmall, lineCount: 9) >= 0)
        #expect(Self.drawnXOrigin(ruler: rulerLarge, textView: textViewLarge, lineCount: 12345) >= 0)
    }
}
