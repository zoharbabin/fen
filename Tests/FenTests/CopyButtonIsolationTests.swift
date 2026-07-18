import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Harness gate 3 for issue #28: proves `copy-button.js` holds no state that survives a new
/// document load, per rule 1.1 -- loads a first document, copies its code block (putting the
/// button into its "Copied" state and touching the pasteboard), then loads a second, different
/// document into the same `WKWebView`/coordinator and asserts none of the first document's DOM
/// or button state carries over. Mirrors `GFMAlertsIsolationTests.swift`'s interleaving intent,
/// adapted to sequential loads since this is DOM/JS state injected by `HTMLComposer`, not a
/// Swift-instance concern.
@Suite("Copy button isolation")
struct CopyButtonIsolationTests {
    @Test @MainActor
    func secondDocumentLoadNeverInheritsFirstDocumentsButtonOrPasteboardState() async throws {
        let firstWebView = try await renderPreviewWebView(
            markdown: "```swift\nlet first = 1\n```"
        ) { prefs in prefs.htmlCopyButton = true }
        _ = try await pollUntilTrue(firstWebView, js: "document.querySelector('.fen-copy-button') !== null")

        _ = try await firstWebView.evaluateJavaScript("document.querySelector('.fen-copy-button').click();")
        _ = try await pollUntilTrue(
            firstWebView,
            js: "document.querySelector('.fen-copy-button').textContent === 'Copied'"
        )
        #expect(NSPasteboard.general.string(forType: .string) == "let first = 1\n")

        let secondWebView = try await renderPreviewWebView(
            markdown: "```swift\nlet second = 2\n```"
        ) { prefs in prefs.htmlCopyButton = true }
        _ = try await pollUntilTrue(secondWebView, js: "document.querySelector('.fen-copy-button') !== null")

        let secondButtonLabel = try await secondWebView.evaluateJavaScript(
            "document.querySelector('.fen-copy-button').textContent"
        )
        let secondContainerCount = try await secondWebView.evaluateJavaScript(
            "document.querySelectorAll('.fen-code-block-container').length"
        )
        #expect((secondButtonLabel as? String) == "Copy")
        #expect((secondContainerCount as? Int) == 1)

        _ = try await secondWebView.evaluateJavaScript("document.querySelector('.fen-copy-button').click();")
        _ = try await pollUntilTrue { NSPasteboard.general.string(forType: .string) == "let second = 2\n" }
    }
}
