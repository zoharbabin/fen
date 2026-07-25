import AppKit
@testable import FenCore
import Foundation
import Testing

/// End-to-end verification of the editor gutter's real `NSLayoutManager` geometry (issue #21) --
/// not a string/content assertion, per this repo's rule against string-only render assertions.
/// Drives `visibleGutterLineFragments` (shared by `EditorGutterRulerView` on macOS and
/// `EditorGutterView` on iOS) against an actual laid-out `NSTextContainer`.
@Suite("Editor gutter line numbering")
struct EditorGutterTests {
    private struct LaidOutDocument {
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let lineStartOffsets: [Int]
    }

    /// Attaches a real NSTextView/NSScrollView/NSWindow stack (mirroring
    /// EditorGutterIsolationTests.swift's makeAttachedTextView) rather than a bare
    /// NSTextStorage/NSLayoutManager/NSTextContainer -- a layout manager with no view/window
    /// behind it never resolves real line-fragment geometry inside the swift test host process.
    @MainActor
    private static func layOut(text: String, containerWidth: CGFloat = 300) -> LaidOutDocument {
        let textStorage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: CGSize(width: containerWidth, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: containerWidth, height: 200),
            textContainer: textContainer
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 200))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: containerWidth, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView

        // Forces layout now rather than lazily on first geometry query, so every test below
        // reads a fully laid-out document instead of racing TextKit's lazy layout pass.
        layoutManager.ensureLayout(for: textContainer)
        return LaidOutDocument(
            layoutManager: layoutManager,
            textContainer: textContainer,
            lineStartOffsets: computeLineStartOffsets(text: text)
        )
    }

    @Test("An empty document produces an empty gutter without crashing")
    @MainActor
    func emptyDocumentProducesEmptyGutterWithoutCrashing() {
        let doc = Self.layOut(text: "")
        let fragments = visibleGutterLineFragments(
            layoutManager: doc.layoutManager,
            textContainer: doc.textContainer,
            visibleRect: CGRect(x: 0, y: 0, width: 300, height: 1000),
            lineStartOffsets: doc.lineStartOffsets
        )
        #expect(fragments.isEmpty)
    }

    @Test("A wrapped source line shows its number only on its first visual line")
    @MainActor
    func wrappedLineShowsNumberOnlyOnFirstVisualLine() {
        let longLine = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        let text = "short one\n\(longLine)\nshort two"
        let doc = Self.layOut(text: text, containerWidth: 200)

        // The whole document fits comfortably within a tall-enough rect, so this exercises the
        // "visible range spans a wrapped source line" case, not the visible-scoping case below.
        let fragments = visibleGutterLineFragments(
            layoutManager: doc.layoutManager,
            textContainer: doc.textContainer,
            visibleRect: CGRect(x: 0, y: 0, width: 200, height: 5000),
            lineStartOffsets: doc.lineStartOffsets
        )

        let sourceLines = fragments.map(\.sourceLine)
        #expect(sourceLines == [1, 2, 3], "Expected exactly one fragment per source line, got \(sourceLines)")

        // The wrapped middle line must actually have wrapped into more than one visual line
        // fragment in the layout manager -- otherwise this document never exercised wrapping and
        // "shows its number only once" would pass vacuously.
        var wrappedVisualLineCount = 0
        var glyphIndex = 0
        let glyphCount = doc.layoutManager.numberOfGlyphs
        while glyphIndex < glyphCount {
            var effectiveRange = NSRange(location: 0, length: 0)
            doc.layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
            wrappedVisualLineCount += 1
            glyphIndex = NSMaxRange(effectiveRange)
            if effectiveRange.length == 0 {
                break
            }
        }
        #expect(
            wrappedVisualLineCount > 3,
            "Expected the long line to wrap into multiple visual lines, got \(wrappedVisualLineCount) total"
        )
    }

    @Test("Gutter draw is scoped to the visible line range on a large document")
    @MainActor
    func gutterDrawScopedToVisibleLinesOnLargeDocument() {
        let lineCount = 500
        let text = (1 ... lineCount).map { "line \($0)" }.joined(separator: "\n")
        let doc = Self.layOut(text: text)

        // A short visible rect near the top must only report a handful of fragments, not all
        // 500 -- proving the lookup is bounded by the visible range, not the document's total
        // line count (rule 4.3).
        let fragments = visibleGutterLineFragments(
            layoutManager: doc.layoutManager,
            textContainer: doc.textContainer,
            visibleRect: CGRect(x: 0, y: 0, width: 300, height: 60),
            lineStartOffsets: doc.lineStartOffsets
        )
        #expect(!fragments.isEmpty)
        #expect(fragments.count < 20, "Expected a small visible-range result, got \(fragments.count) fragments")
        #expect(fragments.first?.sourceLine == 1)
    }

    @Test("A scrolled-down visible range reports the source lines actually visible there")
    @MainActor
    func scrolledVisibleRangeReportsCorrectSourceLines() {
        let lineCount = 200
        let text = (1 ... lineCount).map { "line \($0)" }.joined(separator: "\n")
        let doc = Self.layOut(text: text)

        let firstFragmentHeight = doc.layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
        let scrolledTop = firstFragmentHeight * 100

        let fragments = visibleGutterLineFragments(
            layoutManager: doc.layoutManager,
            textContainer: doc.textContainer,
            visibleRect: CGRect(x: 0, y: scrolledTop, width: 300, height: 60),
            lineStartOffsets: doc.lineStartOffsets
        )

        #expect(!fragments.isEmpty)
        #expect(fragments.first?.sourceLine ?? 0 >= 100)
    }
}
