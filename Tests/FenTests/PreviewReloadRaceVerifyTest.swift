import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Reproduces the bug reported after the font-size zoom feature shipped: "sometimes when I
/// zoom, it jumps around and loses the position the scroll was at." Each zoom step bakes a
/// new `zoom` CSS value into the composed HTML, so `updateNSView`/`updateUIView` treats it as
/// an HTML change and runs a save-scroll/reload round trip (`evaluateJavaScript` to read the
/// current position, then `load` the new HTML, then restore that position). Holding Cmd+ can
/// start a second round trip before the first's async read completes; if that older request's
/// completion lands *after* the newer one's -- ordinary GCD/main-queue scheduling variance, not
/// anything exotic -- it reloads the page back to older HTML and stomps the newer scroll
/// position with its own stale reading, exactly the "jumps around" symptom.
/// `reloadGeneration`/`isCurrentReload` guards against this. This test drives
/// `PreviewWebView.Coordinator` directly (SwiftUI's `Context` has no public initializer) and
/// replicates `updateNSView`'s exact save-scroll/reload structure against a real, still-loaded
/// page, using a real `evaluateJavaScript` read for both requests and an explicit `Task.sleep`
/// *after* the older request's read resolves (simulating its completion landing later than the
/// newer one's) to make the ordering deterministic for CI instead of racing on real timing noise.
@Suite("Preview reload race")
struct PreviewReloadRaceVerifyTest {
    @Test("A stale reload's completion doesn't clobber a newer reload's HTML or scroll position")
    @MainActor
    func staleReloadCompletionIsIgnored() async throws {
        let htmlA = "<!DOCTYPE html><html><body data-page=\"A\"></body></html>"
        let htmlB = "<!DOCTYPE html><html><body data-page=\"B\"></body></html>"

        let parent = PreviewWebView(html: htmlA, baseURL: nil, scrollFraction: 0, onScrollChange: nil)
        let coordinator = parent.makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        coordinator.load(html: htmlA, baseURL: nil, into: webView)
        coordinator.lastHTML = htmlA
        _ = try await pollUntilTrue(webView, js: "document.body.dataset.page === 'A'")

        /// Mirrors updateNSView's reload branch, using a real evaluateJavaScript read (a
        /// literal in place of the source-fraction the real currentSourceFractionJS would
        /// read, since this fixture's page isn't scrollable) with the older request's write
        /// delayed after its already-completed read so the completion order is deterministic.
        func startReload(targetHTML: String, readFraction: CGFloat, writeDelayMS: UInt64) {
            let generation = coordinator.beginReload()
            webView.evaluateJavaScript("\(readFraction);") { result, _ in
                Task { @MainActor in
                    if writeDelayMS > 0 {
                        try? await Task.sleep(for: .milliseconds(writeDelayMS))
                    }
                    guard coordinator.isCurrentReload(generation) else { return }
                    coordinator.savedScrollFraction = (result as? CGFloat) ?? readFraction
                    coordinator.load(html: targetHTML, baseURL: nil, into: webView)
                }
            }
        }

        // Older (stale) request starts first, but its write lands after the newer one's.
        startReload(targetHTML: htmlA, readFraction: 0.2, writeDelayMS: 250)
        startReload(targetHTML: htmlB, readFraction: 0.9, writeDelayMS: 0)

        try await Task.sleep(for: .milliseconds(500))

        let page = try await webView.evaluateJavaScript("document.body.dataset.page")
        #expect(
            page as? String == "B",
            "Expected the page to stay on the newer request's HTML, got \(String(describing: page))"
        )
        #expect(
            coordinator.savedScrollFraction == 0.9,
            "Expected the stale reload's scroll fraction not to overwrite the fresh one"
        )
    }
}
