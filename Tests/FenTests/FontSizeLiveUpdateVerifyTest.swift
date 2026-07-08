import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Reproduces "it still jumps to the top and then back... is there a way to do the zoom
/// in/out without the jumps?": every zoom step used to recompose the HTML with a new literal
/// `zoom` value and reload the page through it, and WKWebView always resets scroll to 0 during
/// navigation before the coordinator's scroll-restore JS runs after `didFinish` -- a visible
/// flash even though the final resting position ended up correct. `PreviewWebView.updateNSView`
/// now routes a font-size-only change through `Coordinator.applyFontSize`, which sets the
/// `--fen-font-scale`/`--fen-font-inverse-scale` custom properties `HTMLComposer.fontScaleCSS`
/// declares and never calls `load()` -- no navigation, so no `didFinish`, so no scroll-to-0.
@Suite("Font-size live update")
struct FontSizeLiveUpdateVerifyTest {
    @Test("A font-size-only change updates the CSS scale live and never navigates")
    @MainActor
    func fontSizeChangeAppliesLiveWithoutReload() async throws {
        let markdown = (1 ... 60).map { "Line \($0) of body text." }.joined(separator: "\n\n")

        func html(fontSize: CGFloat) -> String {
            let prefs = Preferences()
            prefs.fontSize = fontSize
            let renderer = MarkdownRenderer()
            let result = renderer.render(markdown, options: MarkdownRenderer.Options())
            return HTMLComposer().compose(title: nil, body: result.html, preferences: prefs)
        }

        let normalHTML = html(fontSize: Preferences.defaultFontSize)
        let coordinator = PreviewWebView(
            html: normalHTML,
            baseURL: nil,
            fontSize: Preferences.defaultFontSize,
            scrollFraction: 0,
            onScrollChange: nil
        ).makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)

        final class NavCountingDelegate: NSObject, WKNavigationDelegate {
            var navigationCount = 0
            var inner: PreviewWebView.Coordinator
            init(inner: PreviewWebView.Coordinator) {
                self.inner = inner
            }

            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                navigationCount += 1
                inner.webView(webView, didFinish: navigation)
            }
        }
        let navDelegate = NavCountingDelegate(inner: coordinator)
        webView.navigationDelegate = navDelegate
        coordinator.webView = webView

        coordinator.load(html: normalHTML, baseURL: nil, into: webView)
        coordinator.lastHTML = normalHTML
        // Poll the delegate's own counter, not `document.readyState` -- WebKit delivers
        // `didFinish` to the navigation delegate and updates in-page JS state over separate
        // channels that can land out of order, so a JS-side poll isn't a valid proxy for
        // "the Swift-side delegate callback has run."
        _ = try await pollUntilTrue { navDelegate.navigationCount == 1 }
        #expect(navDelegate.navigationCount == 1, "Expected exactly the initial load to navigate")

        // Wait for layout to actually make the page overflow before scrolling it, and scroll
        // partway down. A fixed sleep here isn't reliably long enough on a loaded CI runner.
        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )
        _ = try await webView.evaluateJavaScript("""
        document.documentElement.scrollTop = (document.documentElement.scrollHeight -
            document.documentElement.clientHeight) * 0.4;
        """)
        _ = try await pollUntilTrue(webView, js: "document.documentElement.scrollTop > 0")
        let midScrollTop = try await webView.evaluateJavaScript("document.documentElement.scrollTop") as? Double ?? 0
        #expect(midScrollTop > 0, "Expected the page to be scrollable and scrolled down before zooming")

        // Apply a font-size-only change the same way updateNSView's live-update branch does.
        // applyFontSize's zoom assignment and scroll-fraction read run through an async
        // evaluateJavaScript call, so poll for the CSS scale actually landing rather than
        // sleeping a fixed duration.
        coordinator.applyFontSize(Preferences.defaultFontSize * 2, to: webView)
        _ = try await pollUntilTrue(webView, js: "getComputedStyle(document.body).zoom === '2'")

        #expect(navDelegate.navigationCount == 1, "A font-size-only change must not trigger a page navigation")

        let bodyZoom = try await webView.evaluateJavaScript("getComputedStyle(document.body).zoom") as? String
        #expect(bodyZoom == "2", "Expected the live-updated CSS custom property to scale body text")

        _ = try await pollUntilTrue(webView, js: "document.documentElement.scrollTop > 10")
        let scrollTopAfter = try await webView.evaluateJavaScript(
            "document.documentElement.scrollTop"
        ) as? Double ?? -1
        let message = "Expected the scroll position to survive the live font-size update without " +
            "dropping to 0, got \(scrollTopAfter)"
        #expect(scrollTopAfter > 10, "\(message)")
    }
}
