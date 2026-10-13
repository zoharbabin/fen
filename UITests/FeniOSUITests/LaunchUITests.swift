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

    private func openWorkspacesList() {
        XCTAssertTrue(app.buttons["New Document"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["Workspaces"].firstMatch.exists)

        // The launch screen keeps a hidden copy of each action. Tap the one you can see. An iPad puts
        // Workspaces behind More….
        let visibleWorkspaces = {
            self.app.buttons.matching(identifier: "Workspaces").allElementsBoundByIndex.first { $0.isHittable }
        }
        let more = app.buttons["More…"].firstMatch
        expectation(for: NSPredicate { _, _ in visibleWorkspaces() != nil || more.isHittable }, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        if visibleWorkspaces() == nil {
            more.tap()
        }
        expectation(for: NSPredicate { _, _ in visibleWorkspaces() != nil }, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        visibleWorkspaces()?.tap()
        // With a workspace already granted, a phone opens inside it. Back shows the list.
        let back = app.navigationBars.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testLaunchScreenOffersNewDocumentAndWorkspaces() {
        openWorkspacesList()
        // A sheet inside a NavigationStack, or wider than the screen, once hid the Add button (issue #5).
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add Folder'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(add.isHittable, app.debugDescription)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["New Document"].firstMatch.waitForExistence(timeout: 10))
    }

    /// iOS can't run git, so the Workspaces list offers a GitHub copy that uses the API (issue #60).
    /// Nothing here reaches the network: the form only opens, and Clone waits for an address.
    func testCloneFromGitHubFormOpensAndWaitsForAnAddress() {
        openWorkspacesList()
        var clone = app.buttons["Clone from GitHub…"].firstMatch
        if !clone.waitForExistence(timeout: 5) {
            // A wide toolbar folds the extra buttons into More.
            app.navigationBars.buttons["More"].firstMatch.tap()
            clone = app.buttons["Clone from GitHub…"].firstMatch
        }
        XCTAssertTrue(clone.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(clone.isHittable, app.debugDescription)
        clone.tap()
        let submit = app.navigationBars["Clone from GitHub"].buttons["Clone"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(submit.isEnabled, "Clone must wait for an address")
        let address = app.textFields["CloneAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5), app.debugDescription)
        address.tap()
        address.typeText("zoharbabin/fen")
        XCTAssertTrue(submit.isEnabled, "Clone should enable for owner/name")
        app.navigationBars["Clone from GitHub"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
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
