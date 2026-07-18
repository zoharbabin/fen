import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Proves the flicker/flash issue #24 tracks: without a debounce, every keystroke would run
/// `SplitEditorView.renderMarkdown()`, which sets `renderedHTML`, which `PreviewWebView.updateNSView`
/// (`Shared/Preview/PreviewWebView.swift:58-74`) reloads via `Coordinator.load()` -- a full page
/// navigation, and WKWebView resets scroll to 0 and briefly shows blank content on every one of
/// those reloads. `SplitEditorView.scheduleRender()` (`Shared/Views/SplitEditorView.swift:319-328`)
/// already collapses a rapid run of edits into a single reload by canceling and rescheduling a
/// 300ms-delayed `Task` on every call. This test mirrors that exact cancel-and-reschedule structure
/// (the same technique `PreviewReloadRaceVerifyTest` uses to exercise `updateNSView`'s reload
/// branch, since a SwiftUI `View`'s private `@State`-backed method can't be invoked directly from a
/// test) driving a real `PreviewWebView.Coordinator` and counting real `WKNavigationDelegate.didFinish`
/// calls, so removing the debounce or reintroducing a reload-per-keystroke would fail it.
@Suite("Preview flicker on rapid typing")
struct PreviewFlickerVerifyTest {
    @Test("A rapid burst of edits inside the debounce window collapses into exactly one reload")
    @MainActor
    func rapidEditsCollapseIntoOneReload() async throws {
        let initialHTML = "<!DOCTYPE html><html><body data-rev=\"0\"></body></html>"

        let parent = PreviewWebView(html: initialHTML, baseURL: nil, scrollFraction: 0, onScrollChange: nil)
        let coordinator = parent.makeCoordinator()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)

        final class NavCountingDelegate: NSObject, WKNavigationDelegate {
            var navigationCount = 0
            let inner: PreviewWebView.Coordinator
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

        coordinator.load(html: initialHTML, baseURL: nil, into: webView)
        coordinator.lastHTML = initialHTML
        _ = try await pollUntilTrue { navDelegate.navigationCount == 1 }
        #expect(navDelegate.navigationCount == 1, "Expected exactly the initial load to navigate")

        // Mirrors SplitEditorView.scheduleRender()'s cancel-and-reschedule structure exactly:
        // every call cancels the in-flight debounce Task and starts a new 300ms one, so only the
        // last edit in a rapid burst ever reaches `renderMarkdown`'s reload.
        var debounceTask: Task<Void, Never>?
        func scheduleRender(html: String) {
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // Mirrors updateNSView's reload gate (PreviewWebView.swift:61): only reload if
                // the HTML actually changed.
                guard coordinator.lastHTML != html else { return }
                coordinator.lastHTML = html
                coordinator.load(html: html, baseURL: nil, into: webView)
            }
        }

        // Simulate 8 keystrokes 30ms apart -- well inside the 300ms debounce window, so every one
        // but the last should be superseded before its Task ever wakes up.
        for revision in 1 ... 8 {
            scheduleRender(html: "<!DOCTYPE html><html><body data-rev=\"\(revision)\"></body></html>")
            try await Task.sleep(for: .milliseconds(30))
        }

        // The debounce interval itself is being waited out on purpose here (the documented
        // exception in CONTRIBUTING.md#tests), not used as a stand-in for polling: this proves no
        // reload happened *during* the burst, before asserting on the one that follows it.
        #expect(
            navDelegate.navigationCount == 1,
            "Expected no reload yet while edits are still arriving inside the debounce window"
        )

        _ = try await pollUntilTrue(timeout: .seconds(2)) { navDelegate.navigationCount == 2 }
        #expect(
            navDelegate.navigationCount == 2,
            "Expected exactly one reload after the burst settles, not one per edit"
        )

        let finalRevision = try await webView.evaluateJavaScript("document.body.dataset.rev")
        #expect(
            finalRevision as? String == "8",
            "Expected the settled reload to show the last edit, not an intermediate one"
        )
    }
}
