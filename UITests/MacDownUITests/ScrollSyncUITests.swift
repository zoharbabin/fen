import XCTest

@MainActor
final class ScrollSyncUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // DocumentGroup apps launch into the standard macOS "New/Open" chooser
        // rather than straight into an editor window.
        let newDocumentButton = app.buttons["NewDocumentButton"]
        if newDocumentButton.waitForExistence(timeout: 5) {
            newDocumentButton.click()
        }
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// The accessibility identifiers in `SplitEditorView` land on the
    /// SwiftUI wrapper elements (an `NSScrollView` for the editor, a `Group`
    /// for the WKWebView-backed preview), not on the native `TextView`/
    /// `WebView` roles — so look those up, then descend for interaction.
    private func editorContainer() -> XCUIElement { app.scrollViews["EditorTextView"] }
    private func previewContainer() -> XCUIElement { app.otherElements["PreviewWebView"] }

    /// Types enough headings to make both panes scrollable, without relying
    /// on any prior scroll gesture to "warm up" the WKWebView preview. Typed
    /// as a single `typeText` call — one call per heading pays ~2s of
    /// find-app/synthesize/wait-idle overhead each, which added minutes.
    private func typeLongDocument() {
        let editorScrollView = editorContainer()
        XCTAssertTrue(editorScrollView.waitForExistence(timeout: 5))
        editorScrollView.textViews.firstMatch.click()
        let document = (1...40)
            .map { "## Heading \($0)\n\nSome body text for section \($0).\n\n" }
            .joined()
        app.typeText(document)
    }

    /// Reads the `NN%` accessibility value exposed by `SplitEditorView` for
    /// the given pane, driven directly by the live `ScrollSync` state.
    ///
    /// The preview pane wraps a native `WKWebView`, whose "Other" AX role
    /// doesn't surface `AXValue`, so `SplitEditorView` exposes its fraction
    /// as a label there instead; fall back to that when `.value` is empty.
    private func scrollPercent(of element: XCUIElement) -> Int? {
        if let value = element.value as? String,
            let percent = Int(value.replacingOccurrences(of: "%", with: "")) {
            return percent
        }
        return Int(element.label.replacingOccurrences(of: "%", with: ""))
    }

    private func waitForScrollPercentChange(
        of element: XCUIElement,
        from initial: Int?,
        timeout: TimeInterval = 5
    ) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = scrollPercent(of: element)
            if current != initial {
                return current
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return scrollPercent(of: element)
    }

    func testEditorScrollSyncsPreviewWithoutPriorGesture() throws {
        typeLongDocument()

        let editor = editorContainer()
        let preview = previewContainer()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let previewBefore = scrollPercent(of: preview)

        editor.scroll(byDeltaX: 0, deltaY: -400)

        let previewAfter = waitForScrollPercentChange(of: preview, from: previewBefore)

        XCTAssertNotEqual(
            previewBefore, previewAfter,
            "Preview should sync-scroll on the very first editor scroll gesture, " +
                "with no prior manual preview scroll needed."
        )
    }

    func testPreviewScrollSyncsEditorWithoutPriorGesture() throws {
        typeLongDocument()

        let preview = previewContainer()
        let editor = editorContainer()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let editorBefore = scrollPercent(of: editor)

        preview.scroll(byDeltaX: 0, deltaY: -400)

        let editorAfter = waitForScrollPercentChange(of: editor, from: editorBefore)

        XCTAssertNotEqual(
            editorBefore, editorAfter,
            "Editor should sync-scroll on the very first preview scroll gesture."
        )
    }
}
