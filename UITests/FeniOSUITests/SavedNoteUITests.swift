import XCTest

/// A note that the Share Extension left in Fen's Documents folder opens with its text (issue #43).
/// Share a page from Safari to Fen first, so a note named "Example Domain" exists on the device. Run
/// it on a device with `TEST_RUNNER_FEN_SAVED_NOTE=1` set in the environment of `xcodebuild`.
@MainActor
final class SavedNoteUITests: XCTestCase {
    func testASavedNoteOpensWithItsText() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FEN_SAVED_NOTE"] != nil,
            "Set TEST_RUNNER_FEN_SAVED_NOTE=1 and run on a device that holds a note named Example Domain."
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        // Notes are in the Fen folder under Browse, not in Recents.
        app.buttons["Browse"].firstMatch.tap()
        let phone = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'On My'")).firstMatch
        for _ in 0 ..< 3 where !phone.exists {
            app.swipeDown()
        }
        XCTAssertTrue(phone.exists, "locations: \(app.cells.allElementsBoundByIndex.map(\.label))")
        phone.tap()
        let fenFolder = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Fen'")).firstMatch
        XCTAssertTrue(
            fenFolder.waitForExistence(timeout: 10),
            "in phone: \(app.cells.allElementsBoundByIndex.map(\.label))"
        )
        fenFolder.tap()
        let note = app.cells.matching(NSPredicate(format: "label CONTAINS 'Example Domain'")).firstMatch
        for _ in 0 ..< 10 where !note.exists {
            app.swipeUp()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        note.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        let arrived = NSPredicate(format: "value CONTAINS 'example.com'")
        _ = XCTWaiter().wait(for: [expectation(for: arrived, evaluatedWith: editor)], timeout: 10)
        XCTAssertTrue(arrived.evaluate(with: editor), "the note holds: \(editor.value ?? "nothing")")
    }
}
