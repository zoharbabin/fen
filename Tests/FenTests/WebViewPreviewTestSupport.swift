import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Renders `markdown` through the real `MarkdownRenderer` → `HTMLComposer` →
/// `PreviewSchemeHandler` pipeline and loads it into a `WKWebView`, waiting for
/// navigation to finish. Shared by every e2e preview test so each one asserts
/// against actual rendered DOM/JS state rather than raw HTML strings.
@MainActor
func renderPreviewWebView(
    markdown: String,
    options: MarkdownRenderer.Options = MarkdownRenderer.Options(),
    configurePreferences: (Preferences) -> Void = { _ in },
    baseDirectory: URL? = nil,
    sourceLineCount: Int = 0
) async throws -> WKWebView {
    let renderer = MarkdownRenderer()
    let rendered = renderer.render(markdown, options: options)
    let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: "gfm.verify.\(UUID().uuidString)")))
    configurePreferences(prefs)
    let html = HTMLComposer().compose(
        title: rendered.title,
        body: rendered.html,
        preferences: prefs,
        sourceLineCount: sourceLineCount,
        sourceLineOffset: rendered.frontMatterLineCount
    )

    let handler = PreviewSchemeHandler()
    handler.html = html
    handler.baseDirectory = baseDirectory

    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)

    let delegate = NavDelegate()
    webView.navigationDelegate = delegate
    webView.load(URLRequest(url: PreviewSchemeHandler.previewURL))
    try await delegate.waitForFinish()

    return webView
}

/// Polls `js` until it evaluates truthy or `timeout` elapses. Needed for
/// features (Mermaid, MathJax) that finish rendering asynchronously after
/// the page's `load` event, past the point `renderPreviewWebView` awaits.
@MainActor
func pollUntilTrue(
    _ webView: WKWebView,
    js: String,
    timeout: Duration = .seconds(5)
) async throws -> Bool {
    try await pollUntilTrue(timeout: timeout) {
        try await webView.evaluateJavaScript(js) as? Bool ?? false
    }
}

/// Polls an arbitrary async `condition` until it's true or `timeout` elapses, sleeping briefly
/// between checks. Use this (not a fixed-duration sleep) for state that isn't observable through
/// `webView`'s JS context — e.g. a `WKNavigationDelegate` callback count — since WebKit delivers
/// navigation-delegate callbacks and in-page JS state over separate channels that can land out of
/// order: `document.readyState === 'complete'` has been observed true before `didFinish` reached
/// a Swift-side delegate, so polling JS state alone isn't a valid proxy for native delegate state.
@MainActor
func pollUntilTrue(
    timeout: Duration = .seconds(5),
    _ condition: () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() {
            return true
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    return false
}

@MainActor
final class NavDelegate: NSObject, WKNavigationDelegate {
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
        if finished {
            return
        }
        if let error {
            throw error
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}
