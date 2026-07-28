@testable import FenCore
import Foundation
import Testing
import WebKit

/// End-to-end verification of the preview-side line-number gutter (issue #21), using the same
/// real-pipeline-into-a-live-WKWebView pattern as `ScrollSyncVerifyTest.swift` -- asserts on
/// actual rendered DOM/JS state, not raw HTML strings.
@Suite("Preview line-number gutter")
struct PreviewGutterVerifyTest {
    @Test("Disabled by default: no gutter elements render without the preference")
    @MainActor
    func disabledByDefaultRendersNoGutterElements() async throws {
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: "# Heading\n\nSome paragraph text.",
            options: opts,
            sourceLineCount: 3
        )

        let count = try await webView.evaluateJavaScript("document.querySelectorAll('.fen-gutter-line').length")
        #expect((count as? Int) == 0)
    }

    @Test("Enabling the preference renders one gutter number per leaf source block")
    @MainActor
    func enabledRendersOneNumberPerLeafBlock() async throws {
        let markdown = "# Heading one\n\nFirst paragraph.\n\n## Heading two\n\nSecond paragraph."
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 7
        )

        let anchors = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let list = try #require(anchors as? [[String: Double]])
        #expect(list.count == 4, "Expected one gutter anchor per leaf block, got \(list.count)")

        let lines = list.compactMap { $0["line"] }.map(Int.init)
        #expect(lines == [1, 3, 5, 7], "Expected the four leaf blocks' own starting source lines, got \(lines)")

        let gutterCount = try await webView.evaluateJavaScript("document.querySelectorAll('.fen-gutter-line').length")
        #expect((gutterCount as? Int) == 4)
    }

    @Test("Nested blocks (list item + inner paragraph) contribute exactly one gutter number, not two")
    @MainActor
    func nestedSourceposBlocksDoNotDoubleCount() async throws {
        let markdown = "- First item\n- Second item\n- Third item"
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 3
        )

        let anchors = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let list = try #require(anchors as? [[String: Double]])
        let lines = list.compactMap { $0["line"] }.map(Int.init).sorted()
        #expect(
            lines == [1, 2, 3],
            "Expected one gutter number per list item despite its nested <p> also carrying data-sourcepos, got \(lines)"
        )
    }

    @Test("Front matter's line offset is folded into gutter line numbers")
    @MainActor
    func frontMatterOffsetFoldedIntoGutterNumbers() async throws {
        let frontMatter = "---\ntitle: Test\n---\n"
        let body = "# Heading"
        let markdown = frontMatter + body

        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 4
        )

        let anchors = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let list = try #require(anchors as? [[String: Double]])
        let lines = list.compactMap { $0["line"] }.map(Int.init)
        #expect(
            lines == [4],
            "Expected the heading's raw (front-matter-inclusive) source line, got \(lines)"
        )
    }

    @Test("A table row is numbered once, at its own starting source line, not once per cell")
    @MainActor
    func tableRowShowsStartingSourceLineNotOneNumberPerCell() async throws {
        let markdown = "| A | B |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |"
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 4
        )

        let anchors = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let list = try #require(anchors as? [[String: Double]])
        let lines = list.compactMap { $0["line"] }.map(Int.init)
        #expect(
            lines == [1, 3, 4],
            "Expected exactly one gutter number per row, at each row's own starting source line, got \(lines)"
        )
    }

    @Test("A [TOC] block gets its own gutter number instead of leaving a numbering gap")
    @MainActor
    func tocBlockGetsItsOwnGutterNumber() async throws {
        let markdown = "[TOC]\n\n# First Heading\n\nSome text.\n\n## Second Heading"
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        opts.renderTOC = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 7
        )

        let anchors = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let list = try #require(anchors as? [[String: Double]])
        let lines = list.compactMap { $0["line"] }.map(Int.init)
        #expect(
            lines == [1, 3, 5, 7],
            "Expected the TOC's own starting line (1) alongside every heading/paragraph, got \(lines)"
        )
    }

    @Test("A loose list item's display:contents paragraph gets its true rendered position, not top 0")
    @MainActor
    func looseListParagraphGetsTrueRenderedPosition() async throws {
        // HTMLComposer's listMarkerCSS sets `li > p:first-child { display: contents; }` on a
        // loose list item's first paragraph (list-marker/line-box alignment). That paragraph
        // still carries its own data-sourcepos and qualifies as a gutter leaf, so its position
        // must come from measuring its (still-boxed) contents, not a `display: contents`
        // element's own always-zero getBoundingClientRect().
        let markdown = """
        Intro paragraph to push the list down the page.

        1. First item first paragraph.

           First item second paragraph.

        2. Second item first paragraph.

           Second item second paragraph.
        """
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 9
        )

        let anchors = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let list = try #require(anchors as? [[String: Double]])
        let sorted = list.sorted { ($0["line"] ?? 0) < ($1["line"] ?? 0) }
        let tops = sorted.map { $0["top"] ?? -1 }
        #expect(
            !tops.contains(0),
            "A leaf's top should never be exactly 0 unless it's the very first line, got \(sorted)"
        )
        for i in 1 ..< tops.count {
            #expect(tops[i] >= tops[i - 1], "Anchors must stay in non-decreasing document order, got \(sorted)")
        }
    }

    @Test("Gutter numbers are drawn as plain text content, never innerHTML")
    @MainActor
    func gutterNumbersAreTextOnly() async throws {
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: "# Heading",
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 1
        )

        let html = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-gutter-line').innerHTML"
        )
        #expect((html as? String) == "1")
    }

    @Test("A DOM mutation that reflows later content repaints the gutter with no scroll/resize")
    @MainActor
    func mutationAloneRepaintsGutterWithoutAnExplicitReadOrEvent() async throws {
        // Regression test for the staleness bug the user's screenshot surfaced: markAnchorsDirty
        // used to only set a flag nothing proactively consumed, so a MutationObserver firing with
        // no later scroll/resize (e.g. the split view's WKWebView still settling its frame size
        // after launch, or Mermaid/MathJax/highlight.js inserting content after first paint) left
        // every gutter number frozen at whatever pixel position the very first paint computed.
        let markdown = "# Heading\n\nParagraph one.\n\nParagraph two."
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 5
        )

        // First paint, from the page's own 'load' listener.
        let before = try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.fen-gutter-line')).map(function(e){return e.style.top;})"
        ) as? [String]

        // Simulate async content insertion (Mermaid/MathJax/highlight.js finishing after load)
        // that grows an earlier block's height, with no scroll or resize event following it.
        _ = try await webView.evaluateJavaScript("""
        (function(){
          var filler = document.createElement('div');
          filler.style.height = '300px';
          filler.textContent = 'late-inserted content';
          document.querySelector('h1').after(filler);
        })()
        """)

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-gutter-line')[1].style.top !== '\(before?[1] ?? "")'"
        )

        let after = try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.fen-gutter-line')).map(function(e){return e.style.top;})"
        ) as? [String]

        #expect(before?[0] == after?[0], "The heading, above the inserted filler, shouldn't move")
        let message = "Paragraph one, pushed down 300px by the filler, must repaint to its new " +
            "position with no explicit scroll/resize -- the mutation itself must trigger the repaint"
        #expect(before?[1] != after?[1], "\(message)")
    }

    @Test("Gutter numbers stay aligned with their leaf block at a non-default font size")
    @MainActor
    func gutterStaysAlignedAtNonDefaultFontSize() async throws {
        // Regression test for a double-zoom bug (distinct from the mutation-staleness bug
        // above): HTMLComposer's fontScaleCSS sets `body { zoom: var(--fen-font-scale) }` to
        // scale text with the user's font size. scroll-sync.js's elementTop() reads each leaf's
        // getBoundingClientRect(), which already reflects that zoom, then writes the result as
        // a .fen-gutter-line div's own `top`. That div is itself a descendant of the zoomed
        // body, so without an inverse zoom to cancel it out, the browser applies the same zoom
        // factor to `top` a second time -- painting at `top * zoom` instead of `top`, drifting
        // further from its leaf the further down the page and the further the font size sits
        // from the default. Invisible at the default font size (zoom == 1, where the bug is a
        // no-op), which is why every test that didn't configure a non-default fontSize missed it.
        let markdown = String(repeating: "Paragraph.\n\n", count: 10) + "# Heading\n\nFinal paragraph."
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: {
                $0.editorShowLineNumbers = true
                $0.fontSize = 24
            },
            sourceLineCount: markdown.components(separatedBy: "\n").count
        )

        let diffs = try await webView.evaluateJavaScript("""
        (function(){
          var leaves = Array.from(document.querySelectorAll('[data-sourcepos]:not(td):not(th)'))
            .filter(function(el) { return !el.querySelector('[data-sourcepos]:not(td):not(th)'); });
          var gutterDivs = Array.from(document.querySelectorAll('.fen-gutter-line'));
          var byLine = {};
          gutterDivs.forEach(function(d){ byLine[d.textContent] = d; });

          var out = [];
          leaves.forEach(function(leaf) {
            var startLine = parseInt(leaf.getAttribute('data-sourcepos').split(':')[0], 10);
            var gutterDiv = byLine[String(startLine)];
            if (!gutterDiv) { return; }
            // Text range, not leaf.getBoundingClientRect() -- the leaf's own box top includes
            // CSS half-leading, which is not where its text visually starts (see elementTop's
            // doc comment in scroll-sync.js). The gutter must match the text, not the box.
            var range = document.createRange();
            range.selectNodeContents(leaf);
            var leafTop = range.getBoundingClientRect().top;
            var gutterTop = gutterDiv.getBoundingClientRect().top;
            out.push(gutterTop - leafTop);
          });
          return out;
        })();
        """) as? [Double]

        let diffList = try #require(diffs)
        #expect(!diffList.isEmpty)
        for diff in diffList {
            let message = "Every gutter number's painted position must match its leaf's actual " +
                "rendered position at a non-default font size, got a \(diff)px diff"
            #expect(abs(diff) < 1, "\(message)")
        }
    }

    @Test("A heading's gutter number aligns with its visible text, not its line box's half-leading")
    @MainActor
    func gutterAlignsWithHeadingGlyphsNotLineBoxAtDefaultFontSize() async throws {
        // Regression test for the bug the user's screenshot surfaced at the default font size
        // (distinct from gutterStaysAlignedAtNonDefaultFontSize's double-zoom bug above, which
        // is invisible at zoom == 1): elementTop() used to read a leaf's own
        // getBoundingClientRect().top, which is the top of its CSS line box, not where its text
        // glyphs visually start. A line box includes half-leading -- extra space `line-height`
        // adds beyond the font's own metrics, split evenly above and below the glyphs -- and
        // that gap grows with (line-height - font-size), which is why a heading (large
        // font-size, proportionally larger line-height) drifted visibly further than body text.
        let markdown = "Intro paragraph, so the heading below isn't body's first child.\n\n" +
            "# Fen Markdown Reference & Test Suite\n\nParagraph after heading."
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 5
        )

        let diff = try await webView.evaluateJavaScript("""
        (function(){
          var h1 = document.querySelector('h1');
          var startLine = parseInt(h1.getAttribute('data-sourcepos').split(':')[0], 10);
          var gutterDiv = Array.from(document.querySelectorAll('.fen-gutter-line'))
            .find(function(d){ return d.textContent === String(startLine); });
          var range = document.createRange();
          range.selectNodeContents(h1);
          var textTop = range.getBoundingClientRect().top;
          var gutterTop = gutterDiv.getBoundingClientRect().top;
          return gutterTop - textTop;
        })();
        """) as? Double

        let diffValue = try #require(diff)
        #expect(
            abs(diffValue) < 1,
            "Expected the h1's gutter number to align with its visible text, got a \(diffValue)px diff"
        )
    }
}
