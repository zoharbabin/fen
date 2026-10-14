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
    // sourceLineCount: 0 leaves scroll-sync.js's anchor table empty, so
    // sourceFractionForRendered falls through to the rendered fraction unchanged --
    // isolating this test from the anchor interpolation's own noise, which is
    // unrelated to the zoom-collapse bug this test targets. 20 lines leaves a solid margin on both
    // sides: well over the viewport at the default font size, and well under it at the smallest.
    // 15 landed at exactly 0pt of overflow at the default size, and 25 still overflowed by 7pt at the
    // smallest, so font-metric differences between WebKit versions/runners tipped each one.
    private static let markdown = (1 ... 20).map { "Line \($0) of body text." }.joined(separator: "\n\n")

    /// Forwards `didFinish` to the real `Coordinator`, then counts it. The coordinator's `didFinish`
    /// kicks off an async scroll-restore (`savedScrollFraction`, 0 on the first load) that
    /// overwrites `scrollTop`. WebKit can deliver that callback after `document.readyState`
    /// already reads `complete`, so on a loaded runner it used to land *after* the test scrolled
    /// the page and reset it to the top. Waiting on this counter, not on `readyState`, means the
    /// restore has been issued first, and later `evaluateJavaScript` calls queue behind it.
    @MainActor
    private final class FinishRelay: NSObject, WKNavigationDelegate {
        let coordinator: PreviewWebView.Coordinator
        private(set) var finishCount = 0

        init(_ coordinator: PreviewWebView.Coordinator) {
            self.coordinator = coordinator
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            coordinator.webView(webView, didFinish: navigation)
            finishCount += 1
        }
    }

    private static func html(fontSize: CGFloat) -> String {
        let prefs = Preferences()
        prefs.fontSize = fontSize
        let renderer = MarkdownRenderer()
        let result = renderer.render(markdown, options: MarkdownRenderer.Options())
        return HTMLComposer().compose(title: nil, body: result.html, preferences: prefs)
    }

    @Test("Zooming out past the point where the page stops overflowing doesn't lose the scroll position")
    @MainActor
    func zoomOutCollapseKeepsScrollPosition() async throws {
        let normalHTML = Self.html(fontSize: Preferences.defaultFontSize)
        let coordinator = PreviewWebView(html: normalHTML, baseURL: nil, scrollFraction: 0.5, onScrollChange: nil)
            .makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let relay = FinishRelay(coordinator)
        webView.navigationDelegate = relay
        coordinator.webView = webView

        // Programmatic scrollTop assignments are silently dropped unless the WKWebView is
        // actually attached to a window and laid out -- see PreviewScrollRaceVerifyTest's
        // makeLoadedPreview for the same requirement.
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView

        coordinator.load(html: normalHTML, baseURL: nil, into: webView)
        coordinator.lastHTML = normalHTML
        #expect(
            try await pollUntilTrue(timeout: .seconds(30)) { relay.finishCount == 1 },
            "Expected the first load to finish"
        )

        // Wait for layout to actually make the page overflow before scrolling it -- on a
        // slower CI runner, readyState can flip to 'complete' before scrollHeight reflects
        // the laid-out content, and a fixed sleep isn't reliably long enough there.
        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )

        // Scroll roughly halfway down the (currently overflowing) page.
        _ = try await webView.evaluateJavaScript("""
        document.documentElement.scrollTop = (document.documentElement.scrollHeight -
            document.documentElement.clientHeight) * 0.5;
        """)
        _ = try await pollUntilTrue(webView, js: "document.documentElement.scrollTop > 0")
        let midScrollTop = try await webView.evaluateJavaScript("document.documentElement.scrollTop") as? Double ?? 0
        #expect(midScrollTop > 0, "Expected the page to be scrollable and scrolled down before zooming out")

        // Mirrors updateNSView's save-scroll/reload/restore round trip for a zoom-out step
        // whose new fontSize shrinks the page below the viewport height. It returns once the
        // new page's `didFinish` has run, so its scroll-restore JS is already queued. The caller
        // then polls for the specific post-reload condition it cares about (collapsed height,
        // restored scrollTop).

        func reloadTo(_ newHTML: String) async {
            let finishesBefore = relay.finishCount
            let generation = coordinator.beginReload()
            let result = try? await webView.evaluateJavaScript(currentSourceFractionJS)
            guard coordinator.isCurrentReload(generation) else { return }
            coordinator.savedScrollFraction = (result as? CGFloat) ?? coordinator.savedScrollFraction
            coordinator.load(html: newHTML, baseURL: nil, into: webView)
            // `readyState` would already read `complete` on the old page here.
            _ = try? await pollUntilTrue(timeout: .seconds(30)) { relay.finishCount > finishesBefore }
        }

        // Zoom out enough that the page stops overflowing its viewport.
        await reloadTo(Self.html(fontSize: Preferences.minFontSize))
        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight - document.documentElement.clientHeight <= 0"
        )
        let collapsedMaxScroll = try await webView.evaluateJavaScript("""
        document.documentElement.scrollHeight - document.documentElement.clientHeight;
        """) as? Double ?? -1
        #expect(collapsedMaxScroll <= 0, "Expected this zoom step to make the page stop overflowing")

        // Zoom back in and confirm the position came back instead of staying at the top.
        await reloadTo(normalHTML)
        _ = try await pollUntilTrue(webView, js: "document.documentElement.scrollTop > 10")
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
