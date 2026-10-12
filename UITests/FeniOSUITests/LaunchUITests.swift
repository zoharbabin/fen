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

    func testLaunchScreenOffersNewDocumentAndWorkspaces() {
        XCTAssertTrue(app.buttons["New Document"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["Workspaces"].firstMatch.exists)

        app.buttons["More…"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Workspaces"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Workspaces"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
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
        // The preview shows it as a heading.
        let heading = app.webViews.staticTexts["Hello from iOS"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 20),
            "the preview did not update:\n\(app.debugDescription)"
        )
    }
}
