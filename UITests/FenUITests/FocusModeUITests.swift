import AppKit
import XCTest

/// E2E proof for issue #19 (github.com/zoharbabin/fen/issues/19), harness gate 6: exercises
/// focus/typewriter mode through the real app rather than asserting on Coordinator internals.
@MainActor
final class FocusModeUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Same launch strategy as `FormattingToolbarUITests.launch` -- opens a real file from this
    /// test bundle's sibling app build, in a freshly launched process.
    private func launch(fileURL: URL) {
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

    private func launchWithFreshDocument(text: String) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focus-mode-\(UUID()).md")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        launch(fileURL: tempURL)
    }

    private func editorScrollPercent() -> Int? {
        let editor = documentWindow.scrollViews["EditorTextView"]
        guard let value = editor.value as? String else { return nil }
        return Int(value.replacingOccurrences(of: "%", with: ""))
    }

    /// Rule 4.4/4.5 (issue #19): enabling focus mode and moving the caret to a paragraph far
    /// below the fold recenters the editor's scroll position -- proving the real scroll view
    /// actually moved, not just that some internal offset was computed.
    func testEnablingFocusModeAndMovingCaretRecentersTheEditor() {
        let paragraphs = (1 ... 60).map { "Paragraph \($0) of the document with enough text to take up a full line." }
        launchWithFreshDocument(text: paragraphs.joined(separator: "\n\n"))

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        let toggleButton = documentWindow.buttons["FocusModeToggleButton"]
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))
        toggleButton.click()

        let scrollBefore = editorScrollPercent()

        // Move the caret to the very end of the document, several screens below the fold --
        // typewriter recentering should scroll the editor to keep the caret's line centered.
        editor.textViews.firstMatch.click()
        editor.typeKey(.downArrow, modifierFlags: .command)

        let deadline = Date().addingTimeInterval(5)
        var scrollAfter = editorScrollPercent()
        while Date() < deadline, scrollAfter == scrollBefore {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            scrollAfter = editorScrollPercent()
        }

        attachScreenshot(named: "focus-mode-typewriter-recenter")

        XCTAssertNotEqual(
            scrollBefore, scrollAfter,
            "Moving the caret to the end of a long document with focus mode on should recenter the editor's scroll position"
        )
    }

    /// Rule 3.5 (issue #19): toggling focus mode off and back on, and continuing to type,
    /// never leaves the editor unresponsive or the toggle button unreachable -- a basic
    /// end-to-end smoke test of the real toggle flow a user drives from the toolbar.
    func testTogglingFocusModeOnAndOffKeepsEditorResponsive() {
        launchWithFreshDocument(text: "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        let toggleButton = documentWindow.buttons["FocusModeToggleButton"]
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))

        toggleButton.click()
        toggleButton.click()

        let textView = editor.textViews.firstMatch
        textView.click()
        textView.typeKey(.end, modifierFlags: .command)
        app.typeText(" appended after toggling focus mode twice.")

        let deadline = Date().addingTimeInterval(5)
        var value = textView.value as? String
        while Date() < deadline, value?.contains("appended after toggling") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            value = textView.value as? String
        }

        attachScreenshot(named: "focus-mode-toggle-twice")

        XCTAssertTrue(
            value?.contains("appended after toggling") == true,
            "The editor should remain fully responsive to typing after toggling focus mode off and back on"
        )
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
