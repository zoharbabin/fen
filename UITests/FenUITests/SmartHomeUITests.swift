import AppKit
import XCTest

/// E2E proof for issue #51 (github.com/zoharbabin/fen/issues/51), harness gate 6: exercises the
/// real Home key through the real app. `MarkdownTextEditingTests.smartHomeColumn` already covers
/// the column math; this proves `MarkdownTextView`'s coordinator actually receives the plain Home
/// key at all -- AppKit's StandardKeyBinding.dict binds plain Home to
/// `scrollToBeginningOfDocument:`, not `moveToBeginningOfLine:`/`moveToLeftEndOfLine:` (those need
/// Control+Home), a selector mismatch that left the feature dead despite passing unit tests.
@MainActor
final class SmartHomeUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Same launch strategy as `FormattingToolbarUITests.launch`.
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
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("smart-home-\(UUID()).md")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        launch(fileURL: tempURL)
    }

    /// Rule (issue #51): pressing Home on an indented line moves the caret to the first
    /// non-whitespace character, not true column 0 -- proven by typing a character at that point
    /// and asserting it lands right after the indentation, not at the start of the line.
    func testHomeMovesCaretToFirstNonWhitespaceCharacter() {
        launchWithFreshDocument(text: "    indented line")

        let editor = documentWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command) // caret to end of document/line first

        editor.typeKey(.home, modifierFlags: [])
        editor.typeText("X")

        let deadline = Date().addingTimeInterval(5)
        var value = editor.value as? String
        while Date() < deadline, value?.contains("X") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            value = editor.value as? String
        }

        attachScreenshot(named: "smart-home-first-non-whitespace")
        let message = "Expected Home to land right before the first non-whitespace character, not column 0"
        XCTAssertEqual(value, "    Xindented line", message)
    }

    /// Rule (issue #51): pressing Home a second time, once already at the first non-whitespace
    /// character, moves the caret to true column 0.
    func testSecondHomePressMovesCaretToTrueColumnZero() {
        launchWithFreshDocument(text: "    indented line")

        let editor = documentWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)

        editor.typeKey(.home, modifierFlags: []) // -> first non-whitespace character
        editor.typeKey(.home, modifierFlags: []) // -> true column 0
        editor.typeText("X")

        let deadline = Date().addingTimeInterval(5)
        var value = editor.value as? String
        while Date() < deadline, value?.contains("X") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            value = editor.value as? String
        }

        attachScreenshot(named: "smart-home-column-zero")
        XCTAssertEqual(value, "X    indented line", "Expected a second Home press to land at true column 0")
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
