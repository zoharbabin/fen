import AppKit
import XCTest

/// E2E proof for issue #1 (github.com/zoharbabin/fen/issues/1), harness gate 6: exercises the
/// slash-command menu through the real app rather than asserting on Coordinator internals.
@MainActor
final class SlashCommandMenuUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Same launch strategy as `FocusModeUITests.launch` -- opens a real file from this test
    /// bundle's sibling app build, in a freshly launched process.
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
        // macOS's own window-restoration (Resume) otherwise reopens whatever Fen windows were
        // left over from an earlier test run alongside the document this test opens, and one of
        // those leftover windows can carry an unsaved-changes autosave prompt that steals
        // keyboard focus mid-test -- see Apple Technical Q&A QA1544, and DefaultEditorUITests'
        // identical fix for the same failure mode.
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
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
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("slash-menu-\(UUID()).md")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        launch(fileURL: tempURL)
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

    /// Acceptance criterion 2 (issue #1 rule 3.5): typing `/` at the start of a line opens the
    /// menu, and clicking "Heading" replaces the `/` with a real `# ` heading -- proving the
    /// full trigger-detect-to-commit flow through the real editor and notification path.
    func testTypingSlashOpensMenuAndSelectingHeadingInsertsHeading() {
        launchWithFreshDocument(text: "")

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let textView = editor.textViews.firstMatch
        textView.click()
        app.typeText("/")

        let headingEntry = app.buttons["SlashCommandMenuEntry-h1"]
        XCTAssertTrue(
            waitFor { headingEntry.exists },
            "Typing / at the start of a line should open the slash-command menu"
        )
        attachScreenshot(named: "slash-menu-open")

        headingEntry.click()

        XCTAssertTrue(
            waitFor {
                guard let value = textView.value as? String else { return false }
                return value.hasPrefix("# ")
            },
            "Selecting Heading should replace the / with a real # heading"
        )
        attachScreenshot(named: "slash-menu-heading-inserted")

        XCTAssertFalse(headingEntry.exists, "The menu should close after committing an entry")
    }

    /// Rule 3.4 (issue #1): pressing Escape while the menu is open closes it and leaves the
    /// `/`+filter text exactly as typed -- dismissal must never mutate the document.
    func testEscapeDismissesMenuWithoutMutatingText() {
        launchWithFreshDocument(text: "")

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let textView = editor.textViews.firstMatch
        textView.click()
        app.typeText("/tab")

        let tableEntry = app.buttons["SlashCommandMenuEntry-table"]
        XCTAssertTrue(waitFor { tableEntry.exists }, "Typing /tab should open the menu filtered to Table")

        textView.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            waitFor { !tableEntry.exists },
            "Escape should close the slash-command menu"
        )
        attachScreenshot(named: "slash-menu-escape-dismissed")

        XCTAssertEqual(
            textView.value as? String, "/tab",
            "Escape should dismiss the menu without mutating the /-triggered text"
        )
    }

    /// Rule 3.2 (issue #1): a `/` typed mid-word (inside a URL) never opens the menu.
    func testSlashInsideURLDoesNotOpenMenu() {
        launchWithFreshDocument(text: "")

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let textView = editor.textViews.firstMatch
        textView.click()
        app.typeText("http://example.com")

        XCTAssertTrue(
            waitFor({
                guard let value = textView.value as? String else { return false }
                return value == "http://example.com"
            }, timeout: 3),
            "Typing a URL should land unchanged in the editor"
        )

        let anyMenuEntry = app.buttons["SlashCommandMenuEntry-h1"]
        XCTAssertFalse(anyMenuEntry.exists, "A / typed mid-word inside a URL should never open the slash-command menu")
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
