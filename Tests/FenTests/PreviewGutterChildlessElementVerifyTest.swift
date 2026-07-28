@testable import FenCore
import Foundation
import Testing
import WebKit

/// Split out from `PreviewGutterVerifyTest.swift` to stay under swiftlint's struct-body length
/// gate -- covers the same real-pipeline-into-a-live-WKWebView pattern, just for the childless-
/// leaf-element case specifically.
@Suite("Preview line-number gutter: childless leaf elements")
struct PreviewGutterChildlessElementVerifyTest {
    @Test("A horizontal rule gets its true rendered position, not top 0")
    @MainActor
    func horizontalRuleGetsTrueRenderedPosition() async throws {
        // Regression test for the bug the user's screenshot surfaced: an <hr> has no child
        // nodes, so `document.createRange().selectNodeContents(hr)` selects nothing and its
        // rect comes back with every field at 0 -- elementTop() must fall back to the element's
        // own getBoundingClientRect() for a childless leaf like this, rather than pinning its
        // gutter number to the very top of the page regardless of where it actually renders.
        let markdown = "Intro paragraph to push the rule down the page.\n\n" +
            "# Heading\n\nAnother paragraph before the rule.\n\n---\n\nParagraph after the rule."
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
            "The <hr>'s top should never collapse to exactly 0, got \(sorted)"
        )
        for i in 1 ..< tops.count {
            #expect(tops[i] >= tops[i - 1], "Anchors must stay in non-decreasing document order, got \(sorted)")
        }
    }
}
