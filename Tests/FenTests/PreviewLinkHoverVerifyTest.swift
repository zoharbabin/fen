import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Verifies the status-bar hover feature: `linkHoverObserverJS` reports a hovered link's raw
/// `href` through the `linkHoverHandler` message channel, and `PreviewWebView.Coordinator`
/// forwards it to `onHoverLink`. This test drives `PreviewWebView.Coordinator` directly against a
/// real `WKWebView` (SwiftUI's `Context` has no public initializer) and dispatches synthesized
/// `mouseover`/`mouseout` DOM events rather than a real pointer move, mirroring
/// `PreviewInternalLinkVerifyTest`'s approach for clicks.
@Suite("Preview link hover")
struct PreviewLinkHoverVerifyTest {
    @MainActor
    private func makeLoadedPreview(
        onHoverLink: @escaping (String?) -> Void
    ) async throws -> (webView: WKWebView, coordinator: PreviewWebView.Coordinator) {
        let html = """
        <!DOCTYPE html><html><body>
        <a id="target-link" href="./target.md">Target</a>
        <p id="not-a-link">Not a link</p>
        </body></html>
        """
        let parent = PreviewWebView(
            html: html,
            baseURL: nil,
            scrollFraction: 0,
            onScrollChange: nil,
            onHoverLink: onHoverLink
        )
        let coordinator = parent.makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        let script = WKUserScript(
            source: linkHoverObserverJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(script)
        webView.configuration.userContentController.add(coordinator, name: "linkHoverHandler")

        coordinator.load(html: html, baseURL: nil, into: webView)
        coordinator.lastHTML = html
        _ = try await pollUntilTrue(webView, js: "document.getElementById('target-link') !== null")

        return (webView, coordinator)
    }

    @Test("Hovering a link reports its href, and hovering away clears it")
    @MainActor
    func hoveringLinkReportsHrefAndClearsOnLeave() async throws {
        var hovered: [String?] = []
        let (webView, _) = try await makeLoadedPreview { href in
            hovered.append(href)
        }

        _ = try await webView.evaluateJavaScript("""
        document.getElementById('target-link').dispatchEvent(
            new MouseEvent('mouseover', { bubbles: true, relatedTarget: document.getElementById('not-a-link') })
        );
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(hovered == ["./target.md"], "Expected the hovered link's raw href, got \(hovered)")

        _ = try await webView.evaluateJavaScript("""
        document.getElementById('target-link').dispatchEvent(
            new MouseEvent('mouseout', { bubbles: true, relatedTarget: document.getElementById('not-a-link') })
        );
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(hovered == ["./target.md", nil], "Expected mouseout to clear the hover, got \(hovered)")
    }

    @Test("Hovering non-link content never calls onHoverLink")
    @MainActor
    func hoveringNonLinkContentDoesNothing() async throws {
        var hovered: [String?] = []
        let (webView, _) = try await makeLoadedPreview { href in
            hovered.append(href)
        }

        _ = try await webView.evaluateJavaScript("""
        document.getElementById('not-a-link').dispatchEvent(
            new MouseEvent('mouseover', { bubbles: true })
        );
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(hovered.isEmpty, "Expected hovering plain text never to call onHoverLink, got \(hovered)")
    }
}
