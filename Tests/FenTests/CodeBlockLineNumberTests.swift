@testable import FenCore
import Testing

/// Per-code-block line-number gutter coverage (`preferences.htmlLineNumbers`,
/// `highlight.init.js`), split from `GFMFeatureCoverageTests`/`CodeBlockCoverageTests` to keep
/// that file under swiftlint's file length limit.
@Suite("Code block line numbers")
struct CodeBlockLineNumberTests {
    @Test("Code blocks: line numbers don't leave stray newline text nodes between lines")
    @MainActor
    func codeBlocksWithLineNumbers() async throws {
        let md = "```swift\ntell application \"Fen\"\n    beep\nend tell\n```"
        let webView = try await renderPreviewWebView(markdown: md) { prefs in
            prefs.htmlSyntaxHighlighting = true
            prefs.htmlLineNumbers = true
        }
        let rendered = try await pollUntilTrue(webView, js: "!!document.querySelector('code.fen-line-numbers')")
        #expect(rendered, "Expected the highlighted block to get the fen-line-numbers class")
        let lineCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('code.fen-line-numbers .fen-line').length"
        )
        #expect(
            (lineCount as? Int) == 3,
            "Expected exactly 3 .fen-line spans, one per source line, got \(String(describing: lineCount))"
        )

        // A leftover "\n".join() between <span class="fen-line"> elements leaves a raw text
        // node child on <code> itself; inside <pre> (white-space: pre) that renders as a
        // second, empty line between every already-block-level span, doubling the spacing.
        let hasStrayNewlineTextNode = try await webView.evaluateJavaScript("""
        Array.from(document.querySelector('code.fen-line-numbers').childNodes)
            .some(function (node) { return node.nodeType === Node.TEXT_NODE && node.textContent.includes('\\n'); });
        """)
        #expect(
            (hasStrayNewlineTextNode as? Bool) == false,
            "Found a stray newline text node between .fen-line spans, which doubles the visual line spacing"
        )
    }

    @Test("Code blocks: line numbers stay in sync when a highlight.js token spans multiple lines")
    @MainActor
    func codeBlocksWithLineNumbersAndMultilineToken() async throws {
        // A JS block comment is one hljs token (hljs-comment) whose <span> wraps the embedded
        // newlines -- exactly the shape that broke the old string-split approach (issue #124).
        let md = "```javascript\n/* line one\nline two\nline three */\nvar x = 1;\n```"
        let webView = try await renderPreviewWebView(markdown: md) { prefs in
            prefs.htmlSyntaxHighlighting = true
            prefs.htmlLineNumbers = true
        }
        let rendered = try await pollUntilTrue(webView, js: "!!document.querySelector('code.fen-line-numbers')")
        #expect(rendered, "Expected the highlighted block to get the fen-line-numbers class")

        let lineCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('code.fen-line-numbers .fen-line').length"
        )
        #expect(
            (lineCount as? Int) == 4,
            "Expected exactly 4 .fen-line spans, one per source line, got \(String(describing: lineCount))"
        )

        let noNestedLines = try await webView.evaluateJavaScript("""
        Array.from(document.querySelectorAll('code.fen-line-numbers .fen-line'))
            .every(function (line) { return line.querySelector('.fen-line') === null; });
        """)
        #expect(
            (noNestedLines as? Bool) == true,
            "A .fen-line nested inside another .fen-line renders two overlapping gutter numbers"
        )

        let lineTexts = try await webView.evaluateJavaScript("""
        Array.from(document.querySelectorAll('code.fen-line-numbers .fen-line'))
            .map(function (line) { return line.textContent; });
        """) as? [String]
        #expect(
            lineTexts == ["/* line one", "line two", "line three */", "var x = 1;"],
            "Expected each source line's text preserved verbatim across the split, got \(String(describing: lineTexts))"
        )
    }
}
