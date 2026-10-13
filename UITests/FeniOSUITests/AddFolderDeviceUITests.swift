import XCTest

/// Grant Fen's own folder through the system picker and see its notes in the Workspaces sheet (issue #5).
/// Put a note in Fen's folder first. Set `TEST_RUNNER_FEN_ADD_FOLDER=<part of the note's name>` in the
/// environment of `xcodebuild`. The test removes the workspace again. Your folder is not touched.
@MainActor
final class AddFolderDeviceUITests: XCTestCase {
    func testGrantingFensFolderListsItsNotes() throws {
        guard let noteName = ProcessInfo.processInfo.environment["FEN_ADD_FOLDER"] else {
            throw XCTSkip("Set TEST_RUNNER_FEN_ADD_FOLDER to part of a note's name in Fen's folder.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let more = app.buttons["More…"].firstMatch
        if more.waitForExistence(timeout: 20) {
            more.tap()
        }
        let entry = app.buttons["Workspaces"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        entry.tap()
        // A phone opens inside the last workspace. Back shows the list.
        let back = app.navigationBars.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
        let workspace = app.staticTexts.matching(NSPredicate(format: "label MATCHES '.*, [0-9]+ files?'")).firstMatch
        // Start from an empty list, in case an earlier run stopped early.
        while workspace.waitForExistence(timeout: 3) {
            removeWorkspace(workspace, in: app)
        }

        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add Folder'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()

        // The picker opens where it was last used, and Open chooses the folder it shows. Go to Fen's
        // folder if it isn't showing: Browse, On My iPhone, Fen.
        let inFens = app.buttons["Fen, Actions Menu"].firstMatch
        if !inFens.waitForExistence(timeout: 10) {
            app.buttons["Browse"].firstMatch.tap()
            let phone = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'On My'")).firstMatch
            for _ in 0 ..< 3 where !phone.exists {
                app.swipeDown()
            }
            XCTAssertTrue(phone.exists, app.debugDescription)
            phone.tap()
            let fen = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Fen'")).firstMatch
            XCTAssertTrue(fen.waitForExistence(timeout: 10), app.debugDescription)
            fen.tap()
            XCTAssertTrue(inFens.waitForExistence(timeout: 10), "not inside Fen: \(app.debugDescription)")
        }
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        open.tap()

        // The folder is now a workspace. A phone opens it at once, with its files listed.
        let file = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label ENDSWITH '.md'", noteName))
            .firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30), app.debugDescription)

        // Undo the grant.
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), app.debugDescription)
        removeWorkspace(workspace, in: app)
    }

    /// Removing a workspace never touches its folder.
    private func removeWorkspace(_ row: XCUIElement, in app: XCUIApplication) {
        row.press(forDuration: 1)
        app.buttons["Remove…"].firstMatch.tap()
        let confirm = app.sheets.buttons["Remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 10)
    }
}
