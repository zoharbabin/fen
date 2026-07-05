import AppKit
import Foundation
@testable import FenCore
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

        let renderer = MarkdownRenderer()
        var opts = MarkdownRenderer.Options()
        opts.tables = true
        opts.strikethrough = true
        opts.autolink = true
        opts.taskList = true
        opts.detectFrontMatter = true
        let rendered = renderer.render(markdown, options: opts)

        let prefs = Preferences(defaults: UserDefaults(suiteName: "preview.scheme.verify.\(UUID().uuidString)")!)
        let html = HTMLComposer().compose(title: rendered.title, body: rendered.html, preferences: prefs)

        let handler = PreviewSchemeHandler()
        handler.html = html
        handler.baseDirectory = demoURL.deletingLastPathComponent()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)

        let delegate = NavDelegate()
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: PreviewSchemeHandler.previewURL))

        try await delegate.waitForFinish()

        let naturalWidth = try await webView.evaluateJavaScript(
            "document.querySelector('img') ? document.querySelector('img').naturalWidth : -1"
        )
        let width = (naturalWidth as? Int) ?? Int(naturalWidth as? Double ?? -1)
        #expect(width > 0, "Expected image naturalWidth > 0, got \(String(describing: naturalWidth))")
    }
}

@MainActor
private final class NavDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var error: Error?

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        self.error = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        self.error = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func waitForFinish() async throws {
        if finished { return }
        if let error { throw error }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}
