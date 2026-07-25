import AppKit
import XCTest

/// E2E proof for issue #2 (github.com/zoharbabin/fen/issues/2), harness gate 6: exercises live
/// preview through the real app -- toggling it on/off, clicking a checkbox overlay, and a
/// document shaped to reproduce the glyph-generation-during-edit crash bug found and fixed while
/// building this feature -- rather than asserting on Coordinator internals (already covered by
/// `LivePreviewTests`/`LivePreviewSecurityTests`/`LivePreviewIsolationTests`).
@MainActor
final class LivePreviewUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// Same launch strategy as `FocusModeUITests.launch`/`EditorGutterUITests.launch`, plus an
    /// optional `-editorLivePreviewEnabled YES` argument -- `NSArgumentDomain` overrides the
    /// persisted preference for just this launched process, matching how
    /// `EditorGutterUITests` enables `editorShowLineNumbers` without a toolbar round trip.
    private func launch(fileURL: URL, livePreviewEnabled: Bool) {
        let productsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // FenMacOSUITests-Runner.app
            .deletingLastPathComponent() // Debug
        let appURL = productsDirectory.appendingPathComponent("Fen.app")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appURL.path),
            "Expected the built app under test at \(appURL.path)"
        )

        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .forEach { $0.forceTerminate() }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-editorLivePreviewEnabled", livePreviewEnabled ? "YES" : "NO"]
        let openedExpectation = expectation(description: "Fen opened \(fileURL.lastPathComponent)")
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration) { _, error in
            XCTAssertNil(error)
            openedExpectation.fulfill()
        }
        wait(for: [openedExpectation], timeout: 10)

        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let windowTitle = fileURL.lastPathComponent
        documentWindow = app.windows[windowTitle]
        XCTAssertTrue(documentWindow.waitForExistence(timeout: 5), "Expected a window titled \(windowTitle)")
    }

    private func launchWithFreshDocument(text: String, name: String, livePreviewEnabled: Bool) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID()).md")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        launch(fileURL: tempURL, livePreviewEnabled: livePreviewEnabled)
    }

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate()
    }

    /// Rule 2.1/3.4 (issue #2): toggling Live Preview on (Cmd+Shift+P, the menu shortcut wired
    /// in `macOS/FenApp_macOS.swift`), moving the caret across every styled construct, then
    /// toggling back off, must leave the document's real text byte-identical to the original --
    /// the acceptance criterion "underlying file content is provably unchanged when toggled
    /// on/off," proven here through the real editor rather than a headless Coordinator.
    func testTogglingLivePreviewOnThenOffLeavesDocumentTextByteIdentical() {
        let original = """
        # Heading

        **bold** and *italic* and `code` and [a link](https://example.com).

        - [ ] a task

        > a blockquote

        ![missing](missing.png)
        """
        launchWithFreshDocument(text: original, name: "live-preview-roundtrip", livePreviewEnabled: false)

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let textView = editor.textViews.firstMatch
        textView.click()

        app.typeKey("p", modifierFlags: [.command, .shift])
        // Give the styling pass a moment to run, then move the caret across every paragraph so
        // each construct above gets its marker-hiding pass exercised at least once.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        textView.typeKey(.downArrow, modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        textView.typeKey(.upArrow, modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        attachScreenshot(named: "live-preview-markers-hidden")

        app.typeKey("p", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(
            textView.value as? String, original,
            "Toggling live preview on then off must leave the document text byte-identical"
        )
    }

    /// Rule 2.3 (issue #2): clicking a checkbox overlay toggles the exact `[ ]`/`[x]` marker in
    /// the real underlying text, through the real `NSButton` overlay
    /// (`LivePreviewCheckboxOverlay`, `MarkdownTextView+LivePreview.swift`), not a simulated
    /// selection-based toggle.
    func testClickingCheckboxOverlayTogglesUnderlyingMarker() {
        let text = "- [ ] a task\n\nSecond paragraph, so the task line is not the active line."
        launchWithFreshDocument(text: text, name: "live-preview-checkbox", livePreviewEnabled: true)

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let textView = editor.textViews.firstMatch
        textView.click()

        // Move the caret into the second paragraph so the checkbox's line is inactive and
        // rendered behind its overlay rather than shown as plain editable source.
        textView.typeKey(.downArrow, modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let checkbox = documentWindow.checkBoxes["LivePreviewCheckboxOverlay"]
        XCTAssertTrue(waitFor { checkbox.exists }, "Expected a checkbox overlay for the inactive task line")
        attachScreenshot(named: "live-preview-checkbox-before-toggle")

        checkbox.click()

        XCTAssertTrue(
            waitFor {
                guard let value = textView.value as? String else { return false }
                return value.hasPrefix("- [x] a task")
            },
            "Clicking the checkbox overlay should flip the underlying marker to [x]"
        )
        attachScreenshot(named: "live-preview-checkbox-after-toggle")
    }

    /// Regression coverage for the glyph-generation-during-edit crash bug found and fixed while
    /// implementing this feature: a document with an inactive-paragraph checkbox and image used
    /// to crash AppKit ("attempted glyph generation while textStorage is editing") because
    /// overlay positioning called `rect(forCharacterRange:)` inside the same
    /// `beginEditing()`/`endEditing()` transaction that applied marker-hiding attributes. Typing
    /// into such a document with Live Preview on must keep the app running and responsive.
    func testDocumentWithInactiveCheckboxAndImageDoesNotCrash() {
        let text = """
        First paragraph, this is where the caret starts.

        - [ ] a task line, inactive and rendered behind its checkbox overlay

        ![missing](missing.png)

        Last paragraph.
        """
        launchWithFreshDocument(text: text, name: "live-preview-crash-regression", livePreviewEnabled: true)

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let textView = editor.textViews.firstMatch
        textView.click()
        textView.typeKey(.end, modifierFlags: .command)
        app.typeText(" appended after the crash-regression document rendered.")

        let deadline = Date().addingTimeInterval(5)
        var value = textView.value as? String
        while Date() < deadline, value?.contains("appended after the crash-regression") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            value = textView.value as? String
        }

        attachScreenshot(named: "live-preview-crash-regression")
        XCTAssertTrue(
            value?.contains("appended after the crash-regression") == true,
            "The editor should remain responsive to typing with an inactive checkbox/image on screen"
        )
        XCTAssertTrue(app.exists, "Fen should not have crashed rendering a document with an inactive checkbox/image")
    }

    /// Records visible proof of the flow for harness gate 6, attached to the test result.
    private func attachScreenshot(named name: String) {
        let screenshot = documentWindow.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
