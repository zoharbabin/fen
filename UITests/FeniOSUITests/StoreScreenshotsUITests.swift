import XCTest

/// Takes the iPhone and iPad App Store screenshots (issue #40). It skips unless
/// `TEST_RUNNER_FEN_STORE_SHOTS_DIR` names a folder. Run it through `scripts/make-store-screenshots.sh`,
/// which first puts the sample workspace in the simulator's Fen folder and registers it.
@MainActor
final class StoreScreenshotsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var output: URL!
    private var prefix = "phone"

    override func setUpWithError() throws {
        let dir = try XCTUnwrap(
            ProcessInfo.processInfo.environment["FEN_STORE_SHOTS_DIR"],
            "Set TEST_RUNNER_FEN_STORE_SHOTS_DIR."
        )
        continueAfterFailure = false
        output = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        prefix = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        app = XCUIApplication()
        app.launchArguments = [
            "-htmlMermaid", "YES", "-htmlMathJax", "YES", "-htmlMathJaxInlineDollar", "YES",
            "-editorAppearanceMode", "light", "-previewAppearanceMode", "light",
        ]
        app.launch()
    }

    /// A failed run leaves `debug-<test>.png` next to the pictures, so you can see where it got stuck.
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let output {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png
                .write(to: output
                    .appendingPathComponent("debug-\(prefix)-\(name.split(separator: " ").last!.dropLast()).png"))
        }
    }

    private func save(_ name: String) throws {
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: output.appendingPathComponent("\(prefix)-\(name).png"))
    }

    /// Opens the workspaces sheet from the launch screen.
    private func showWorkspaces() {
        let more = app.buttons["More…"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        let entry = app.buttons["Workspaces"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        entry.tap()
    }

    /// Opens a note from Fen's folder in the document browser. The browser may already be in that folder.
    private func open(_ name: String) {
        let browse = app.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 30))
        browse.tap()
        let note = app.cells.matching(identifier: name).firstMatch
        if !note.waitForExistence(timeout: 5) {
            let fen = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Fen'")).firstMatch
            if !fen.waitForExistence(timeout: 5) {
                let device = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'On My'")).firstMatch
                for _ in 0 ..< 3 where !device.exists {
                    app.swipeDown()
                }
                XCTAssertTrue(device.exists, "no On My location")
                device.tap()
            }
            // On iPad the sidebar can float over the folder. A tap on the empty area closes it.
            if !fen.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).tap()
            }
            XCTAssertTrue(
                fen.waitForExistence(timeout: 10),
                "no Fen folder: \(app.cells.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" })"
            )
            fen.tap()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 10), "no note named \(name)")
        note.tap()
    }

    private var isPad: Bool {
        prefix == "pad"
    }

    /// The preview of an open note. A phone shows the editor first, an iPad shows both.
    private func showPreview(waitingFor text: String) {
        let preview = app.buttons["Preview"].firstMatch
        if !isPad, preview.waitForExistence(timeout: 20) {
            preview.tap()
        }
        let heading = app.webViews.firstMatch.staticTexts[text]
        XCTAssertTrue(heading.waitForExistence(timeout: 40), "the preview never showed \(text)")
    }

    func testEditor() throws {
        open("Launch plan, md")
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 20))
        if isPad {
            XCTAssertTrue(app.webViews.firstMatch.staticTexts["Beta feedback"].waitForExistence(timeout: 40))
        }
        try save("editor")
    }

    func testPreview() throws {
        open("Launch plan, md")
        showPreview(waitingFor: "Beta feedback")
        try save("preview")
    }

    func testMath() throws {
        open("Pricing, md")
        showPreview(waitingFor: "Break-even")
        _ = app.webViews.firstMatch.descendants(matching: .any).matching(identifier: "LTV").firstMatch
            .waitForExistence(timeout: 10)
        try save("math")
    }

    /// Opens the workspace list. The sheet is narrow on both devices and opens inside the last workspace,
    /// so go back first.
    private func showWorkspaceList() {
        showWorkspaces()
        let back = app.buttons["BackButton"].firstMatch
        if back.waitForExistence(timeout: 10) {
            back.tap()
        }
    }

    func testSearch() throws {
        showWorkspaceList()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no search field")
        field.tap()
        field.typeText("subscription price\n")
        // A "Similar meaning" label means the meaning search has answered, not only the word search.
        XCTAssertTrue(app.staticTexts["Similar meaning"].firstMatch.waitForExistence(timeout: 40), "no result")
        try save("search")
    }

    func testAsk() throws {
        showWorkspaceList()
        let ask = app.buttons["Ask"].firstMatch.exists ? app.buttons["Ask"].firstMatch : app.switches["Ask"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 15), "no Ask toggle")
        ask.tap()
        let field = app.textFields["What did we decide about…?"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no question field")
        field.tap()
        field.typeText("Why did we choose a yearly price?\n")
        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 240), "no answer")
        try save("ask")
    }
}
