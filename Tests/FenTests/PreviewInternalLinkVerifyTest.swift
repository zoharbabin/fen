import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Reproduces "internal links... don't work": a relative-path link to another local Markdown
/// file resolves through `PreviewSchemeHandler` to a `fen-preview://` URL, so the old binary
/// `shouldOpenExternally` check (only external vs. same-scheme) let it fall through to
/// `.allow`, which made `WKWebView` try to navigate to and load that file's raw text as HTML in
/// place, instead of opening it as a document. `PreviewSchemeHandler.internalLinkTarget(for:)`
/// now distinguishes a same-page anchor (stays on `index.html`, still allowed in place) from a
/// link that resolves to a *different* file on disk (canceled and handed to
/// `PreviewWebView.onOpenInternalLink` instead). This test drives `PreviewWebView.Coordinator`
/// directly (SwiftUI's `Context` has no public initializer) against a real `WKWebView` and a
/// real click, not a synthesized `WKNavigationAction`.
@Suite("Preview internal links")
struct PreviewInternalLinkVerifyTest {
    @MainActor
    private func makeTempDirectoryWithTarget() throws -> (directory: URL, targetURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fen-internal-link-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targetURL = directory.appendingPathComponent("target.md")
        try "# Target\n".write(to: targetURL, atomically: true, encoding: .utf8)
        return (directory, targetURL)
    }

    @Test("Clicking a relative-path link to another local file cancels navigation and reports the resolved file URL")
    @MainActor
    func relativeLinkToAnotherFileOpensInternally() async throws {
        let (directory, targetURL) = try makeTempDirectoryWithTarget()

        var openedURL: URL?
        let html = """
        <!DOCTYPE html><html><body>
        <a id="target-link" href="./target.md">Target</a>
        <a id="anchor-link" href="#section">Section</a>
        <h2 id="section">Section</h2>
        </body></html>
        """

        let parent = PreviewWebView(
            html: html,
            baseURL: nil,
            scrollFraction: 0,
            onScrollChange: nil,
            onOpenInternalLink: { url in openedURL = url }
        )
        let coordinator = parent.makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        // load()'s baseURL is a fake in-directory document path so `PreviewSchemeHandler`
        // resolves the clicked link's relative path against `directory`, exactly like a real
        // open document's `fileURL` would.
        let fakeDocumentURL = directory.appendingPathComponent("index.md")
        coordinator.load(html: html, baseURL: fakeDocumentURL, into: webView)
        coordinator.lastHTML = html
        _ = try await pollUntilTrue(webView, js: "document.getElementById('target-link') !== null")

        _ = try await webView.evaluateJavaScript("document.getElementById('target-link').click();")
        try await Task.sleep(for: .milliseconds(300))

        let opened = try #require(openedURL)
        #expect(
            opened.standardizedFileURL.path == targetURL.standardizedFileURL.path,
            "Expected the resolved target file URL, got \(opened)"
        )

        let stillOnPreview = try await webView.evaluateJavaScript("document.getElementById('target-link') !== null")
        #expect(
            (stillOnPreview as? Bool) == true,
            "Expected the preview's WKWebView to stay on the original page, not navigate to the linked file"
        )

        try? FileManager.default.removeItem(at: directory)
    }

    @Test("Clicking a same-page anchor still navigates in place and never calls onOpenInternalLink")
    @MainActor
    func samePageAnchorStaysInPreview() async throws {
        var openedURL: URL?
        let html = """
        <!DOCTYPE html><html><body>
        <a id="anchor-link" href="#section">Section</a>
        <h2 id="section">Section</h2>
        </body></html>
        """

        let parent = PreviewWebView(
            html: html,
            baseURL: nil,
            scrollFraction: 0,
            onScrollChange: nil,
            onOpenInternalLink: { url in openedURL = url }
        )
        let coordinator = parent.makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        coordinator.load(html: html, baseURL: nil, into: webView)
        coordinator.lastHTML = html
        _ = try await pollUntilTrue(webView, js: "document.getElementById('anchor-link') !== null")

        _ = try await webView.evaluateJavaScript("document.getElementById('anchor-link').click();")
        try await Task.sleep(for: .milliseconds(300))

        #expect(openedURL == nil, "Expected a same-page anchor click never to call onOpenInternalLink")
    }

    @Test("internalLinkTarget rejects a path that escapes baseDirectory via a symlink")
    @MainActor
    func internalLinkTargetRejectsSymlinkEscape() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fen-internal-link-traversal-\(UUID().uuidString)")
        let base = directory.appendingPathComponent("root")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secretURL = outside.appendingPathComponent("secret.md")
        try "secret".write(to: secretURL, atomically: true, encoding: .utf8)
        let escapeLink = base.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)

        let handler = PreviewSchemeHandler()
        handler.baseDirectory = base

        let url = try #require(URL(string: "\(PreviewSchemeHandler.scheme)://local/escape/secret.md"))
        #expect(
            handler.internalLinkTarget(for: url) == nil,
            "Expected a symlink pointing outside baseDirectory to be rejected, not resolved to \(secretURL)"
        )

        try? FileManager.default.removeItem(at: directory)
    }

    @Test("internalLinkTarget rejects an absolute-path escape and returns nil for a same-page anchor")
    @MainActor
    func internalLinkTargetRejectsAbsoluteEscapeAndAnchors() throws {
        let handler = PreviewSchemeHandler()
        handler.baseDirectory = FileManager.default.temporaryDirectory

        let absoluteEscape = try #require(URL(string: "\(PreviewSchemeHandler.scheme)://local/../../etc/passwd"))
        #expect(handler.internalLinkTarget(for: absoluteEscape) == nil)

        let anchor = try #require(URL(string: "\(PreviewSchemeHandler.scheme)://local/index.html#section"))
        #expect(handler.internalLinkTarget(for: anchor) == nil)

        let external = try #require(URL(string: "https://fen.md"))
        #expect(handler.internalLinkTarget(for: external) == nil)
    }
}
