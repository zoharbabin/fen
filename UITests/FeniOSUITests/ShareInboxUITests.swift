import XCTest

/// Text left by the Share Extension becomes a document (issue #43). The test plays the extension's
/// part: it writes the `.md` file into the App Group inbox. That folder is in the simulator's App
/// Group container, which only exists in a build signed with the entitlement. Run it with
/// `scripts/test-share-inbox.sh`, which signs ad hoc, installs the app and passes the folder in.
@MainActor
final class ShareInboxUITests: XCTestCase {
    private var inbox: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["FEN_SHARE_INBOX"]
        try XCTSkipUnless(path?.isEmpty == false, "FEN_SHARE_INBOX is not set. Run scripts/test-share-inbox.sh.")
        inbox = try URL(fileURLWithPath: XCTUnwrap(path), isDirectory: true)
        try? FileManager.default.removeItem(at: inbox)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let inbox {
            try? FileManager.default.removeItem(at: inbox)
        }
    }

    func testSharedTextBecomesADocument() throws {
        try "# Shared from Safari\n\nA quote worth keeping.\n"
            .write(to: inbox.appendingPathComponent("Shared from Safari.md"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launch()

        // Fen saves the shared text as a note when it starts, so the document list shows it.
        let note = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Shared from Safari'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), app.debugDescription)
        note.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        expectation(for: NSPredicate(format: "value CONTAINS 'A quote worth keeping.'"), evaluatedWith: editor)
        waitForExpectations(timeout: 10)

        // The inbox file is now marked used, and is not offered again.
        let names = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
        XCTAssertEqual(names, ["Shared from Safari.md.consumed"])
    }
}
