import AppKit
import XCTest

/// E2E proof for issue #13 (github.com/zoharbabin/fen/issues/13), harness gate 6: exercises the
/// formatting toolbar through the real app rather than asserting on the transform function alone.
@MainActor
final class FormattingToolbarUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Same launch strategy as `DocumentOutlineUITests.launch` -- opens a real file from this
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
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("formatting-\(UUID()).md")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        launch(fileURL: tempURL)
    }

    /// Rule 5.4 (issue #13): every action is reachable from a toolbar button in the shared
    /// toolbar -- clicking "Bold" on a real selection wraps it with `**` in the real text view.
    func testClickingBoldToolbarButtonWrapsTheSelection() {
        launchWithFreshDocument(text: "hello world")

        let editor = documentWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.doubleClick() // selects "hello", the word under the default caret position

        let formattingMenu = documentWindow.menuButtons["FormattingMenuButton"]
        XCTAssertTrue(formattingMenu.waitForExistence(timeout: 5))
        formattingMenu.click()

        let boldButton = documentWindow.menuItems["FormatBoldButton"]
        XCTAssertTrue(boldButton.waitForExistence(timeout: 5))
        boldButton.click()

        let deadline = Date().addingTimeInterval(5)
        var value = editor.value as? String
        while Date() < deadline, value?.contains("**") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            value = editor.value as? String
        }

        attachScreenshot(named: "formatting-bold-toolbar")
        XCTAssertTrue(value?.contains("**") == true, "Expected the selection to be wrapped with ** after clicking Bold")
    }

    /// Rule 5.4 (issue #13): the table action inserts a template independent of selection.
    func testClickingTableToolbarButtonInsertsATemplate() {
        launchWithFreshDocument(text: "")

        let editor = documentWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        let formattingMenu = documentWindow.menuButtons["FormattingMenuButton"]
        XCTAssertTrue(formattingMenu.waitForExistence(timeout: 5))
        formattingMenu.click()

        let tableButton = documentWindow.menuItems["FormatTableButton"]
        XCTAssertTrue(tableButton.waitForExistence(timeout: 5))
        tableButton.click()

        let deadline = Date().addingTimeInterval(5)
        var value = editor.value as? String
        while Date() < deadline, value?.contains("|") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            value = editor.value as? String
        }

        attachScreenshot(named: "formatting-table-toolbar")
        XCTAssertTrue(value?.contains("|") == true, "Expected a table template to be inserted")
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
