import XCTest

/// The GitHub conflict screen on a real device (issue #62). Two steps, because the sync state is written
/// between them with `scripts/test-conflict-screen-device.sh`:
///
/// 1. `FEN_CONFLICT_PHASE=grant`: grant the `fen-conflict-demo` folder in Fen's Documents as a workspace.
/// 2. `FEN_CONFLICT_PHASE=resolve`: open it, see the conflict, choose Use GitHub's, and check the conflict is gone.
///
/// Run `scripts/test-conflict-screen-device.sh <device UDID>`. The workspace and folder stay on the device.
@MainActor
final class ConflictScreenDeviceUITests: XCTestCase {
    private var phase: String? {
        ProcessInfo.processInfo.environment["FEN_CONFLICT_PHASE"]
    }

    private func openWorkspaceList(_ app: XCUIApplication) {
        let more = app.buttons["More…"].firstMatch
        if more.waitForExistence(timeout: 20) {
            more.tap()
        }
        let entry = app.buttons["Workspaces"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        entry.tap()
    }

    func testGrantTheDemoFolder() throws {
        guard phase == "grant" else { throw XCTSkip("Set TEST_RUNNER_FEN_CONFLICT_PHASE=grant.") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openWorkspaceList(app)
        let back = app.navigationBars.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add Folder'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()

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
        }
        let demo = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'fen-conflict-demo'")).firstMatch
        // The picker is a lazy grid: scroll until the folder's cell exists.
        for direction in 0 ..< 6 where !demo.waitForExistence(timeout: 2) {
            if direction < 3 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(demo.exists, app.debugDescription)
        demo.tap()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        open.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'README'")).firstMatch
                .waitForExistence(timeout: 30),
            app.debugDescription
        )
    }

    func testConflictScreenListsTheNoteAndUseGitHubsSettlesIt() throws {
        guard phase == "resolve" else { throw XCTSkip("Set TEST_RUNNER_FEN_CONFLICT_PHASE=resolve.") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openWorkspaceList(app)
        // A phone opens inside the last workspace. The header carries the sync controls.
        let fix = app.buttons["Fix Conflicts"].firstMatch
        XCTAssertTrue(fix.waitForExistence(timeout: 30), app.debugDescription)
        let summary = app.staticTexts["1 note has a conflict to fix"].firstMatch
        XCTAssertTrue(summary.exists, "no conflict line:\n\(app.debugDescription)")
        add(app.screenshot(), named: "workspace-header-with-conflict")

        fix.tap()
        let title = app.navigationBars["Conflicts"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["README.md"].firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["You and GitHub both changed this note."].firstMatch.exists)
        XCTAssertTrue(app.buttons["Keep Mine"].firstMatch.exists)
        let theirs = app.buttons["Use GitHub's"].firstMatch
        XCTAssertTrue(theirs.exists)
        add(app.screenshot(), named: "conflict-screen")

        theirs.tap()
        // Settling the last conflict closes the screen and clears the warning.
        XCTAssertTrue(title.waitForNonExistence(timeout: 30), "screen stayed open:\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Fix Conflicts"].firstMatch.waitForExistence(timeout: 3))
        add(app.screenshot(), named: "after-use-githubs")
    }

    private func add(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
