import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// End-to-end verification of issue #127 rule 3 (preview-pane focus sync): proves the DOM/CSS
/// effect of `window.__fenScrollSync.setFocusRange` through a real `WKWebView`, not just a
/// string-content assertion on composed HTML -- the pattern
/// `Tests/FenTests/PreviewSchemeHandlerVerifyTest.swift` establishes.
@Suite("Preview focus-mode sync end-to-end verification")
struct PreviewFocusModeSyncVerifyTest {
    private static let markdown = """
    # Heading one

    First paragraph under heading one.

    ## Heading two

    Second paragraph under heading two.
    """

    /// Disables `.fen-focus-dim`'s `transition` before reading a computed style. WebKit pauses
    /// CSS transitions on a `document.hidden` page -- true for the offscreen `WKWebView` these
    /// tests render into -- so the opacity change from adding/removing the class never completes,
    /// and `getComputedStyle` would keep reading the pre-transition value back forever. Disabling
    /// the transition makes the class toggle apply its target opacity immediately, which is what
    /// these tests care about (the steady-state effect of `setFocusRange`), not the 120ms fade.
    @MainActor
    private func disableFocusDimTransition(in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript(
            "document.querySelectorAll('[data-sourcepos]').forEach(function (el) { el.style.transition = 'none'; });"
        )
    }

    @MainActor
    private func opacity(of selectorText: String, in webView: WKWebView) async throws -> Double {
        let js = """
        (function () {
            var elements = document.querySelectorAll('[data-sourcepos]');
            for (var i = 0; i < elements.length; i++) {
                if (elements[i].textContent.indexOf(\(String(reflecting: selectorText))) !== -1) {
                    return parseFloat(getComputedStyle(elements[i]).opacity);
                }
            }
            return -1;
        })();
        """
        let result = try await webView.evaluateJavaScript(js)
        return (result as? Double) ?? Double(result as? Int ?? -1)
    }

    private static var sourcePositionOptions: MarkdownRenderer.Options {
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        return opts
    }

    @Test("setFocusRange dims every leaf block outside the active range and undims the rest")
    @MainActor
    func setFocusRangeDimsOutsideActiveRange() async throws {
        let webView = try await renderPreviewWebView(
            markdown: Self.markdown, options: Self.sourcePositionOptions, sourceLineCount: 7
        )
        try await disableFocusDimTransition(in: webView)

        // The active range covers only "Second paragraph under heading two." (source line 7).
        _ = try await webView.evaluateJavaScript(
            "window.__fenScrollSync.setFocusRange(7, 7);"
        )

        let activeOpacity = try await opacity(of: "Second paragraph", in: webView)
        let dimmedHeadingOpacity = try await opacity(of: "Heading one", in: webView)
        let dimmedParagraphOpacity = try await opacity(of: "First paragraph", in: webView)

        #expect(activeOpacity == 1, "Expected the active paragraph to render at full opacity")
        #expect(dimmedHeadingOpacity == 0.35, "Expected a heading outside the active range to be dimmed")
        #expect(dimmedParagraphOpacity == 0.35, "Expected a paragraph outside the active range to be dimmed")
    }

    @Test("setFocusRange(null, null) clears every dim it previously applied")
    @MainActor
    func setFocusRangeNullClearsAllDimming() async throws {
        let webView = try await renderPreviewWebView(
            markdown: Self.markdown, options: Self.sourcePositionOptions, sourceLineCount: 7
        )
        try await disableFocusDimTransition(in: webView)

        _ = try await webView.evaluateJavaScript("window.__fenScrollSync.setFocusRange(7, 7);")
        let dimmedBeforeClear = try await opacity(of: "Heading one", in: webView)
        #expect(dimmedBeforeClear == 0.35)

        _ = try await webView.evaluateJavaScript("window.__fenScrollSync.setFocusRange(null, null);")

        let headingOpacity = try await opacity(of: "Heading one", in: webView)
        let paragraphOpacity = try await opacity(of: "First paragraph", in: webView)
        #expect(headingOpacity == 1, "Expected clearing the focus range to restore full opacity")
        #expect(paragraphOpacity == 1, "Expected clearing the focus range to restore full opacity")
    }
}
