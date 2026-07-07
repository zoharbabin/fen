import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Reproduces "when I zoom out, it can jump back to the beginning and stay there": zooming out
/// shrinks the preview's rendered height via the `zoom` CSS the font-size preference applies to
/// `body`, and once it shrinks enough that the page no longer overflows its viewport,
/// `currentSourceFractionJS`'s `scrollTop / (scrollHeight - clientHeight)` used to divide by a
/// clamped `1`, always reading back ~0 regardless of where the page had actually been scrolled
/// to. `updateNSView`/`updateUIView` save that corrupted read as `savedScrollFraction` before
/// every reload, so the position was lost the instant a zoom step made the page stop overflowing
/// -- and stayed lost, since every later reload just re-confirmed the same collapsed 0. Fixed by
/// having the JS return `null` in that state, which both `Coordinator`s already fall back to the
/// last known-good fraction for.
@Suite("Zoom-out scroll position")
struct ZoomOutScrollPositionVerifyTest {
    @Test("Zooming out past the point where the page stops overflowing doesn't lose the scroll position")
    @MainActor
    func zoomOutCollapseKeepsScrollPosition() async throws {
        let markdown = (1 ... 15).map { "Line \($0) of body text." }.joined(separator: "\n\n")

        // sourceLineCount: 0 leaves scroll-sync.js's anchor table empty, so
        // sourceFractionForRendered falls through to the rendered fraction unchanged --
        // isolating this test from the anchor interpolation's own noise, which is
        // unrelated to the zoom-collapse bug this test targets.
        func html(fontSize: CGFloat) -> String {
            let prefs = Preferences()
            prefs.fontSize = fontSize
            let renderer = MarkdownRenderer()
            let result = renderer.render(markdown, options: MarkdownRenderer.Options())
            return HTMLComposer().compose(title: nil, body: result.html, preferences: prefs)
        }

        let normalHTML = html(fontSize: Preferences.defaultFontSize)
        let coordinator = PreviewWebView(html: normalHTML, baseURL: nil, scrollFraction: 0.5, onScrollChange: nil)
            .makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        coordinator.load(html: normalHTML, baseURL: nil, into: webView)
        coordinator.lastHTML = normalHTML
        _ = try await pollUntilTrue(webView, js: "document.readyState === 'complete'")

        // Scroll roughly halfway down the (currently overflowing) page.
        try await Task.sleep(for: .milliseconds(300))
        _ = try await webView.evaluateJavaScript("""
        document.documentElement.scrollTop = (document.documentElement.scrollHeight -
            document.documentElement.clientHeight) * 0.5;
        """)
        try await Task.sleep(for: .milliseconds(100))
        let midScrollTop = try await webView.evaluateJavaScript("document.documentElement.scrollTop") as? Double ?? 0
        #expect(midScrollTop > 0, "Expected the page to be scrollable and scrolled down before zooming out")

        /// Mirrors updateNSView's save-scroll/reload/restore round trip for a zoom-out step
        /// whose new fontSize shrinks the page below the viewport height.
        func reloadTo(_ newHTML: String) async {
            let generation = coordinator.beginReload()
            let result = try? await webView.evaluateJavaScript(currentSourceFractionJS)
            guard coordinator.isCurrentReload(generation) else { return }
            coordinator.savedScrollFraction = (result as? CGFloat) ?? coordinator.savedScrollFraction
            coordinator.load(html: newHTML, baseURL: nil, into: webView)
            _ = try? await pollUntilTrue(webView, js: "document.readyState === 'complete'")
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Zoom out enough that the page stops overflowing its viewport.
        await reloadTo(html(fontSize: Preferences.minFontSize))
        let collapsedMaxScroll = try await webView.evaluateJavaScript("""
        document.documentElement.scrollHeight - document.documentElement.clientHeight;
        """) as? Double ?? -1
        #expect(collapsedMaxScroll <= 0, "Expected this zoom step to make the page stop overflowing")

        // Zoom back in and confirm the position came back instead of staying at the top.
        await reloadTo(normalHTML)
        let restoredScrollTop = try await webView.evaluateJavaScript(
            "document.documentElement.scrollTop"
        ) as? Double ?? -1

        #expect(
            coordinator.savedScrollFraction > 0.3,
            "Expected the ~0.5 scroll fraction to survive the zoom-out collapse, got \(coordinator.savedScrollFraction)"
        )
        #expect(
            restoredScrollTop > 10,
            "Expected zooming back in to restore the scrolled-down position, got scrollTop=\(restoredScrollTop)"
        )
    }
}
