import XCTest

/// A note that another device saved in iCloud Drive arrives here with its text and its version history (issue #59).
/// It skips unless `TEST_RUNNER_FEN_ICLOUD_MARKER` holds the marker line the Mac wrote, and
/// `TEST_RUNNER_FEN_ICLOUD_NAME` the file name (default `test-file`). Run it through `scripts/test-icloud-device.sh`,
/// which writes the marker on the Mac first. It prints the version rows it sees, prefixed with `ICLOUD-IOS`.
@MainActor
final class ICloudDeviceUITests: XCTestCase {
    func testAnICloudNoteArrivesWithItsHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        let marker = try XCTUnwrap(environment["FEN_ICLOUD_MARKER"], "Set TEST_RUNNER_FEN_ICLOUD_MARKER.")
        let name = environment["FEN_ICLOUD_NAME"] ?? "test-file"
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        app.buttons["Browse"].firstMatch.tap()
        // The browser opens where it was last: Recents, or a folder. Go up until iCloud Drive's top level shows the
        // note.
        let note = app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        let back = app.buttons["BackButton"].firstMatch
        for _ in 0 ..< 4 where !note.waitForExistence(timeout: 5) {
            // Cells exist only while they show, so scroll the folder before leaving it.
            for _ in 0 ..< 8 where !note.exists {
                app.swipeUp()
            }
            if note.exists {
                break
            }
            if back.exists {
                back.tap()
            } else {
                let drive = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'iCloud Drive'")).firstMatch
                XCTAssertTrue(drive.waitForExistence(timeout: 5), app.debugDescription)
                drive.tap()
            }
        }
        XCTAssertTrue(
            note.waitForExistence(timeout: 30),
            "in iCloud Drive: \(app.cells.allElementsBoundByIndex.map(\.label))"
        )
        note.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60), app.debugDescription)
        let arrived = NSPredicate(format: "value CONTAINS %@", marker)
        _ = XCTWaiter().wait(for: [expectation(for: arrived, evaluatedWith: editor)], timeout: 240)
        XCTAssertTrue(arrived.evaluate(with: editor), "the note holds: \(editor.value ?? "nothing")")
        print("ICLOUD-IOS text arrived: true")

        // On a phone in portrait the actions are in the More menu of the navigation bar.
        let history = app.buttons.matching(NSPredicate(
            format: "identifier == 'VersionHistoryButton' OR label == 'Version History'"
        )).firstMatch
        if !history.waitForExistence(timeout: 5) {
            let more = app.buttons["OverflowBarButtonItem"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
            more.tap()
        }
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        history.tap()
        let title = app.navigationBars["Version History"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), app.debugDescription)
        // The list loads after the spinner. Either rows or the empty message ends the wait.
        let empty = app.staticTexts["No earlier versions"]
        let rows = app.cells
        let loaded = NSPredicate { _, _ in empty.exists || rows.count > 0 }
        _ = XCTWaiter().wait(for: [expectation(for: loaded, evaluatedWith: nil)], timeout: 60)
        print("ICLOUD-IOS versions: \(empty.exists ? 0 : rows.count)")
        for cell in rows.allElementsBoundByIndex.prefix(10) {
            print("ICLOUD-IOS row: \(cell.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
        }
    }
}
