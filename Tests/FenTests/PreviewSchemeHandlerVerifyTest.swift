import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

@Suite("PreviewSchemeHandler end-to-end verification")
struct PreviewSchemeHandlerVerifyTest {
    @Test("Relative-path image in demo.md loads through fen-preview:// scheme")
    @MainActor
    func imageLoadsThroughSchemeHandler() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let demoURL = repoRoot.appendingPathComponent("assets/demo.md")
        let markdown = try String(contentsOf: demoURL, encoding: .utf8)

        var opts = MarkdownRenderer.Options()
        opts.tables = true
        opts.strikethrough = true
        opts.autolink = true
        opts.taskList = true
        opts.detectFrontMatter = true

        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            baseDirectory: demoURL.deletingLastPathComponent()
        )

        let naturalWidth = try await webView.evaluateJavaScript(
            "document.querySelector('img') ? document.querySelector('img').naturalWidth : -1"
        )
        let width = (naturalWidth as? Int) ?? Int(naturalWidth as? Double ?? -1)
        #expect(width > 0, "Expected image naturalWidth > 0, got \(String(describing: naturalWidth))")
    }

    @Test("Loose task list checkbox renders on the same line as its item text")
    @MainActor
    func looseTaskListCheckboxIsInlineWithText() async throws {
        let markdown = """
        - [ ] item one
        - [ ] item two

          continuation text
        - [ ] item three
        """

        var opts = MarkdownRenderer.Options()
        opts.taskList = true
        let webView = try await renderPreviewWebView(markdown: markdown, options: opts)

        let sameLineJS = """
        (function () {
            var checkbox = document.querySelector('li > input[type="checkbox"]');
            var p = checkbox ? checkbox.nextElementSibling : null;
            if (!checkbox || !p || p.tagName !== 'P') { return false; }
            var checkboxTop = checkbox.getBoundingClientRect().top;
            var pTop = p.getBoundingClientRect().top;
            return Math.abs(checkboxTop - pTop) < 5;
        })();
        """
        let sameLine = try await webView.evaluateJavaScript(sameLineJS)
        #expect((sameLine as? Bool) == true, "Expected checkbox and item text to render on the same line")
    }

    @Test("Same-page anchors (TOC, footnote backrefs) never hand off to the OS")
    func tocAnchorsStayInPreview() throws {
        let anchor = try #require(URL(string: "\(PreviewSchemeHandler.scheme)://local/index.html#links-and-images"))
        #expect(
            !PreviewSchemeHandler.shouldOpenExternally(anchor),
            "A fen-preview:// anchor jump must not be handed to NSWorkspace/UIApplication"
        )
    }

    @Test("External links (http/https, mailto) hand off to the OS")
    func externalLinksOpenExternally() throws {
        let http = try #require(URL(string: "https://fen.md"))
        let mail = try #require(URL(string: "mailto:hello@fen.md"))
        #expect(PreviewSchemeHandler.shouldOpenExternally(http))
        #expect(PreviewSchemeHandler.shouldOpenExternally(mail))
    }
}
