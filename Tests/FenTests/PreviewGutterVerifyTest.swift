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
}
