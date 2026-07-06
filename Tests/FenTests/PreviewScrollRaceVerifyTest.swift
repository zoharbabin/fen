import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Reproduces the real-world drift the user reported after `ScrollSyncVerifyTest`'s
/// stale-anchor-table fix landed: automated UI tests that scroll one paced gesture at a
/// time never caught it, because XCUITest's `scroll(byDeltaX:deltaY:)` waits for the app
/// to idle after every synthesized event, well past the point WKWebView actually dispatches
/// its DOM 'scroll' event. This test drives `PreviewWebView.Coordinator` directly (SwiftUI's
/// `Context` has no public initializer, so `makeNSView` can't be called from a test) and lets
/// the browser's real, asynchronous event timing run — exposing that a programmatic scroll
/// assignment's self-triggered 'scroll' event fires *after* the Swift-side external-scroll
/// guard had already cleared, leaking a stale position back through onScrollChange as if the
/// user had scrolled, and compounding into drift the deeper a document goes.
@Suite("Preview scroll assignment race")
struct PreviewScrollRaceVerifyTest {
    @MainActor
    private func makeLoadedPreview(
        onScrollChange: @escaping (CGFloat) -> Void
    ) async throws -> (webView: WKWebView, coordinator: PreviewWebView.Coordinator) {
        let html = "<!DOCTYPE html><html><body><div style=\"height:5000px\"></div></body></html>"
        let parent = PreviewWebView(html: html, baseURL: nil, scrollFraction: 0, onScrollChange: onScrollChange)
        let coordinator = parent.makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        // Programmatic scrollTop assignments are silently dropped unless the WKWebView is
        // actually attached to a window and laid out — an off-screen, unattached web view
        // (as other tests in this file use for pure element-position reads) never scrolls.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView

        let script = WKUserScript(
            source: scrollObserverJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(script)
        webView.configuration.userContentController.add(coordinator, name: "scrollHandler")

        coordinator.load(html: html, baseURL: nil, into: webView)
        coordinator.lastHTML = html

        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )
        // Let didFinish's own load-time scroll-restore round trip actually finish before the
        // test's own assignment — a fixed sleep here previously raced it under CI's slower/
        // busier runner: if didFinish's restore-to-0 write landed after this test's own 0.8
        // assignment, it silently stomped the scroll position back to 0. Polling on
        // __fenSuppressScrollEvent's explicit `false` (only reached after scrollAssignmentJS's
        // nested requestAnimationFrame pair fires) proves that write has actually committed.
        _ = try await pollUntilTrue(webView, js: "window.__fenSuppressScrollEvent === false")

        return (webView, coordinator)
    }

    @Test("A programmatic scroll assignment's own DOM scroll event doesn't leak back as a user scroll")
    @MainActor
    func selfTriggeredScrollEventDoesNotLeakThroughOnScrollChange() async throws {
        var receivedFractions: [CGFloat] = []
        let (webView, coordinator) = try await makeLoadedPreview { fraction in
            receivedFractions.append(fraction)
        }

        // WKWebView fires the resulting DOM 'scroll' event asynchronously, around the next
        // frame — well after evaluateJavaScript's own completion handler runs. Waiting here
        // gives that event time to actually fire, which is exactly what a paced XCUITest
        // gesture's built-in "wait for idle" step also does, hiding this bug from it.
        coordinator.applyScrollFraction(0.8, to: webView)
        try await Task.sleep(for: .milliseconds(400))

        #expect(
            receivedFractions.isEmpty,
            """
            Expected no scroll events to leak through onScrollChange from this app's own \
            scroll assignment, got \(receivedFractions)
            """
        )

        let finalFraction = try await webView.evaluateJavaScript("""
        document.documentElement.scrollTop /
            Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
        """)
        let final = try #require(finalFraction as? Double)
        #expect(abs(final - 0.8) < 0.05, "Expected the scroll assignment to actually take effect, got \(final)")
    }
}
