import XCTest

/// The iOS app in the simulator: the launch screen, the Workspaces sheet, and a new document
/// (issues #5, #42). Run it on an iPhone and on an iPad.
@MainActor
final class LaunchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Without a `UILaunchScreen` entry, iPhone runs the app letterboxed in a small frame.
    func testAppFillsTheScreen() {
        XCTAssertTrue(app.buttons["New Document"].firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        let screen = app.frame
        XCTAssertEqual(
            window.height,
            screen.height,
            accuracy: 60,
            "window \(window) is smaller than the screen \(screen)"
        )
    }

    func testLaunchScreenOffersNewDocumentAndWorkspaces() {
        XCTAssertTrue(app.buttons["New Document"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["Workspaces"].firstMatch.exists)

        app.buttons["More…"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Workspaces"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Workspaces"].firstMatch.tap()
        // With a workspace already granted, a phone opens inside it. Back shows the list.
        let back = app.navigationBars.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
        // A sheet inside a NavigationStack, or wider than the screen, once hid the Add button (issue #5).
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add Folder'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(add.isHittable, app.debugDescription)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["New Document"].firstMatch.waitForExistence(timeout: 10))
    }

    func testNewDocumentTakesTypingAndShowsAPreview() {
        XCTAssertTrue(app.buttons["New Document"].firstMatch.waitForExistence(timeout: 20))
        // The launch screen keeps a hidden copy of each action. Tap the one you can see.
        let visibleButton = {
            self.app.buttons.matching(identifier: "New Document").allElementsBoundByIndex.first { $0.isHittable }
        }
        let isVisible = NSPredicate { _, _ in visibleButton() != nil }
        expectation(for: isVisible, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        visibleButton()?.tap()
        let editor = app.textViews.firstMatch
        _ = editor.waitForExistence(timeout: 12)
        if !editor.exists, app.alerts.firstMatch.exists {
            // On the simulator the system sometimes reports "Unable to Import Document" for a file it
            // did create. The file opens from Recents, so use that.
            app.alerts.buttons["OK"].tap()
            app.collectionViews.cells.firstMatch.tap()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        editor.tap()
        editor.typeText("# Hello from iOS\n\n- one\n- two\n")
        let typed = app.textViews["EditorTextView"]
        let hasText = NSPredicate(format: "value CONTAINS 'Hello from iOS'")
        _ = typed.waitForExistence(timeout: 5)
        expectation(for: hasText, evaluatedWith: typed)
        waitForExpectations(timeout: 10)
        // A phone shows one pane at a time, so switch to the preview first.
        if app.windows.firstMatch.frame.width <= 600 {
            let preview = app.segmentedControls["ViewModePicker"].buttons["Preview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 10), "no Preview segment:\n\(app.debugDescription)")
            preview.tap()
        }
        let heading = app.webViews.staticTexts["Hello from iOS"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the preview did not update:\n\(app.debugDescription)")
    }
}
