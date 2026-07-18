import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Verifies the copy-to-clipboard button injected by `copy-button.js`/`copy-button.css`
/// (issue #28). Drives a real `WKWebView` through the full `MarkdownRenderer` ->
/// `HTMLComposer` -> `PreviewSchemeHandler` pipeline (via `renderPreviewWebView`) and asserts
/// on actual DOM state and the real system pasteboard, not on raw HTML strings -- per
/// CLAUDE.md's rule that anything ending up on screen needs a WebKit-driven test, following
/// `PreviewLinkHoverVerifyTest.swift`'s synthetic-event-dispatch pattern.
@Suite("Preview copy button")
struct PreviewCopyButtonVerifyTest {
    private static let markdown = """
    ```swift
    let x = 42
    ```
    """

    @Test("Rule 5.1/5.4: button and container are injected when enabled, absent when disabled")
    @MainActor
    func buttonPresenceTogglesWithPreference() async throws {
        let enabledWebView = try await renderPreviewWebView(markdown: Self.markdown) { prefs in
            prefs.htmlCopyButton = true
        }
        _ = try await pollUntilTrue(enabledWebView, js: "document.querySelector('.fen-copy-button') !== null")
        let containerCount = try await enabledWebView.evaluateJavaScript(
            "document.querySelectorAll('.fen-code-block-container').length"
        )
        #expect((containerCount as? Int) == 1)

        let disabledWebView = try await renderPreviewWebView(markdown: Self.markdown) { prefs in
            prefs.htmlCopyButton = false
        }
        _ = try await pollUntilTrue(disabledWebView, js: "document.querySelector('pre') !== null")
        let disabledButtonCount = try await disabledWebView.evaluateJavaScript(
            "document.querySelectorAll('.fen-copy-button').length"
        )
        let disabledContainerCount = try await disabledWebView.evaluateJavaScript(
            "document.querySelectorAll('.fen-code-block-container').length"
        )
        #expect((disabledButtonCount as? Int) == 0)
        #expect((disabledContainerCount as? Int) == 0)
    }

    @Test("Rules 2.1/5.2/5.3: clicking copies the code block's exact text, flips the label, and reverts")
    @MainActor
    func clickingCopiesExactTextAndShowsFeedback() async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("sentinel-before-copy", forType: .string)

        let webView = try await renderPreviewWebView(markdown: Self.markdown) { prefs in
            prefs.htmlCopyButton = true
        }
        _ = try await pollUntilTrue(webView, js: "document.querySelector('.fen-copy-button') !== null")

        _ = try await webView.evaluateJavaScript("document.querySelector('.fen-copy-button').click();")

        _ = try await pollUntilTrue { pasteboard.string(forType: .string) != "sentinel-before-copy" }
        #expect(pasteboard.string(forType: .string) == "let x = 42\n")

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelector('.fen-copy-button').textContent === 'Copied'"
        )

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelector('.fen-copy-button').textContent === 'Copy'",
            timeout: .seconds(3)
        )
    }

    @Test("Rule 4.1: no leftover <textarea> remains in the DOM after a copy")
    @MainActor
    func noLeftoverTextareaAfterCopy() async throws {
        let webView = try await renderPreviewWebView(markdown: Self.markdown) { prefs in
            prefs.htmlCopyButton = true
        }
        _ = try await pollUntilTrue(webView, js: "document.querySelector('.fen-copy-button') !== null")

        _ = try await webView.evaluateJavaScript("document.querySelector('.fen-copy-button').click();")
        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelector('.fen-copy-button').textContent === 'Copied'"
        )

        let textareaCount = try await webView.evaluateJavaScript("document.querySelectorAll('textarea').length")
        #expect((textareaCount as? Int) == 0)
    }

    @Test("Rule 5.2: copied text is unaffected by syntax highlighting or line-number decoration")
    @MainActor
    func copiedTextFlattensHighlightingAndLineNumberSpans() async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("sentinel-before-copy", forType: .string)

        let webView = try await renderPreviewWebView(markdown: Self.markdown) { prefs in
            prefs.htmlCopyButton = true
            prefs.htmlSyntaxHighlighting = true
            prefs.htmlLineNumbers = true
        }
        _ = try await pollUntilTrue(webView, js: "document.querySelector('.fen-line') !== null")
        _ = try await pollUntilTrue(webView, js: "document.querySelector('.fen-copy-button') !== null")

        _ = try await webView.evaluateJavaScript("document.querySelector('.fen-copy-button').click();")
        _ = try await pollUntilTrue { pasteboard.string(forType: .string) != "sentinel-before-copy" }

        #expect(pasteboard.string(forType: .string) == "let x = 42\n")
    }
}
