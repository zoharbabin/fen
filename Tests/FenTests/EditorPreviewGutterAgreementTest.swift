import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Cross-pane verification that the editor gutter (real `NSLayoutManager` geometry, mirroring
/// `EditorGutterTests.swift`) and the preview gutter (real `WKWebView`, mirroring
/// `PreviewGutterVerifyTest.swift`) agree on where a given source line renders, against the same
/// mixed-density document -- the acceptance criteria's explicit "editor and preview line numbers
/// agree ... for a real document mixing prose, wrapped paragraphs, code fences, tables, and
/// blockquotes" check (issue #21).
@Suite("Editor/preview gutter cross-pane agreement")
struct EditorPreviewGutterAgreementTest {
    private struct MixedDocument {
        let markdown: String
        let sourceLineCount: Int
        let markerRawLine: Int
    }

    /// A long wrapped paragraph, a fenced code block, a table, a blockquote, and 30 short
    /// headings -- the same "prose, wrapped paragraphs, code fences, tables, and blockquotes"
    /// shape the acceptance criteria calls for, engineered so the marker heading's naive
    /// line-count fraction sits mid-document but its actual rendered position (after the wrapped
    /// paragraph consumes most of the visual height) sits much later -- exercising the same
    /// word-wrap-density correction `ScrollSyncVerifyTest`'s `unevenDensityDocument()` does, on
    /// both panes at once.
    private static func mixedContentDocument() -> MixedDocument {
        var lines = [String(repeating: "word ", count: 800).trimmingCharacters(in: .whitespaces)]
        lines.append("")
        lines.append("```swift")
        lines.append("let x = 1")
        lines.append("```")
        lines.append("")
        lines.append("| A | B |")
        lines.append("| - | - |")
        lines.append("| 1 | 2 |")
        lines.append("")
        lines.append("> A blockquote.")

        var markerRawLine = 0
        for i in 1 ... 30 {
            lines.append("")
            lines.append("## Heading \(i)")
            if i == 3 {
                markerRawLine = lines.count
            }
        }
        lines.append("")
        lines.append("Trailing paragraph.")
        return MixedDocument(
            markdown: lines.joined(separator: "\n"),
            sourceLineCount: lines.count,
            markerRawLine: markerRawLine
        )
    }

    /// The marker heading's rendered-fraction position in a real, laid-out `NSTextView` --
    /// attaching a real `NSTextView`/`NSScrollView`/`NSWindow` stack, since a bare
    /// `NSLayoutManager` with no view/window behind it never resolves real line-fragment
    /// geometry inside the `swift test` host process (established in `EditorGutterTests.swift`).
    @MainActor
    private func editorRenderedFraction(for doc: MixedDocument, containerWidth: CGFloat = 900) -> CGFloat {
        let textStorage = NSTextStorage(string: doc.markdown, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: CGSize(width: containerWidth, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: containerWidth, height: 200), textContainer: textContainer
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
        layoutManager.ensureLayout(for: textContainer)

        let lineStartOffsets = computeLineStartOffsets(text: doc.markdown)
        let markerCharIndex = lineStartOffsets[doc.markerRawLine - 1]
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: markerCharIndex)
        let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let totalHeight = layoutManager.usedRect(for: textContainer).height
        return fragmentRect.origin.y / totalHeight
    }

    @Test("Editor and preview gutters place the same source line at a comparably-skewed rendered fraction")
    @MainActor
    func editorAndPreviewAgreeOnMarkerLinePosition() async throws {
        let doc = Self.mixedContentDocument()
        let editorFraction = editorRenderedFraction(for: doc)

        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: doc.markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: doc.sourceLineCount
        )
        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )

        let previewFraction = try await webView.evaluateJavaScript("""
        (function () {
            var anchors = window.__fenScrollSync.lineNumberAnchors();
            var marker = null;
            for (var i = 0; i < anchors.length; i++) {
                if (anchors[i].line === \(doc.markerRawLine)) { marker = anchors[i]; break; }
            }
            if (!marker) { return null; }
            return marker.top / document.documentElement.scrollHeight;
        })();
        """)
        let previewFractionValue = try #require(previewFraction as? Double)

        let naiveFraction = Double(doc.markerRawLine - 1) / Double(doc.sourceLineCount)
        #expect(
            editorFraction > naiveFraction + 0.05,
            "Expected the wrapped paragraph to push the marker's editor position past its naive line fraction"
        )
        #expect(
            previewFractionValue > naiveFraction + 0.05,
            "Expected the wrapped paragraph to push the marker's preview position past its naive line fraction"
        )
        #expect(
            abs(editorFraction - previewFractionValue) < 0.2,
            "Expected editor (\(editorFraction)) and preview (\(previewFractionValue)) fractions to roughly agree"
        )
    }

    // MARK: - Issue #113 rule 5.1: shared breakpoints make interpolated fractions agree tightly

    /// The editor's own `NSLayoutManager`-backed `lineTopForCharacterIndex` closure, over the
    /// same real text view/window stack `editorRenderedFraction` builds -- factored out so both
    /// the naive-measurement test above and this anchor-table test share one geometry source.
    @MainActor
    private func editorLineTopClosure(
        for doc: MixedDocument, containerWidth: CGFloat = 900
    ) -> (top: (Int) -> CGFloat?, totalHeight: CGFloat) {
        let textStorage = NSTextStorage(string: doc.markdown, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: CGSize(width: containerWidth, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: containerWidth, height: 200), textContainer: textContainer
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
        layoutManager.ensureLayout(for: textContainer)

        let totalHeight = layoutManager.usedRect(for: textContainer).height
        let top: (Int) -> CGFloat? = { charIndex in
            let length = (doc.markdown as NSString).length
            guard charIndex >= 0, charIndex < length else { return nil }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil).origin.y
        }
        return (top, totalHeight)
    }

    @Test("Editor and preview anchor tables built from the shared blockStartLines breakpoint set agree tightly")
    @MainActor
    func sharedBreakpointsMakeInterpolatedFractionsAgree() async throws {
        let doc = Self.mixedContentDocument()

        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let renderResult = MarkdownRenderer().render(doc.markdown, options: opts)

        let webView = try await renderPreviewWebView(
            markdown: doc.markdown,
            options: opts,
            sourceLineCount: doc.sourceLineCount
        )
        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )

        // Rule 5.1's breakpoint-equality proof: the breakpoints the editor's anchor table would
        // be fed equal the raw-line-adjusted data-sourcepos start-line set the preview's own
        // computeAnchors() walks -- same regex-over-HTML extraction, same DOM query, same lines.
        let previewStartLines = try await webView.evaluateJavaScript("""
        (function () {
            var elements = document.querySelectorAll("[data-sourcepos]");
            var lines = [];
            for (var i = 0; i < elements.length; i++) {
                var line = parseInt(elements[i].getAttribute("data-sourcepos").split(":")[0], 10);
                if (lines.length === 0 || lines[lines.length - 1] !== line) {
                    lines.push(line);
                }
            }
            return lines;
        })();
        """)
        let previewStartLinesValue = try #require(previewStartLines as? [Int])
        // No front matter in this document, so the raw-source-line adjustment is a no-op.
        #expect(renderResult.blockStartLines == previewStartLinesValue)

        let (lineTop, totalHeight) = editorLineTopClosure(for: doc)
        let editorAnchors = computeEditorLineAnchors(
            text: doc.markdown,
            totalHeight: totalHeight,
            visibleHeight: 200,
            breakpoints: renderResult.blockStartLines,
            lineTopForCharacterIndex: lineTop
        )

        let naiveFraction = Double(doc.markerRawLine - 1) / Double(doc.sourceLineCount)
        let editorInterpolated = interpolateEditorAnchor(
            editorAnchors, from: \.source, to: \.rendered, value: CGFloat(naiveFraction)
        )
        let previewInterpolated = try await webView.evaluateJavaScript(
            "window.__fenScrollSync.renderedFractionForSource(\(naiveFraction));"
        )
        let previewInterpolatedValue = try #require(previewInterpolated as? Double)

        #expect(
            abs(Double(editorInterpolated) - previewInterpolatedValue) < 0.02,
            """
            Expected editor (\(editorInterpolated)) and preview (\(previewInterpolatedValue)) interpolated \
            rendered fractions -- both built from the same blockStartLines breakpoint set -- to agree far \
            tighter than the raw cross-engine measurement above, since they now sample identical points
            """
        )
    }
}
