import AppKit
import XCTest

/// The workspace settings sheet and the search scope controls, in the real app with a throwaway home
/// folder (`CFFIXED_USER_HOME`), so `~/.fen` is untouched.
@MainActor
final class WorkspaceControlsUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fen-workspace-controls-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("ws/notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("home"),
            withIntermediateDirectories: true
        )
        try "# Plan\n\n- pricing is twelve dollars\n- ship in Q4\n"
            .write(to: notes.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try "---\ntype: Task\nstatsu: done\n---\n\n# Ship it\n"
            .write(to: notes.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        try "# Roadmap\n\nSee [[plan]] for the numbers.\n"
            .write(to: notes.appendingPathComponent("roadmap.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: root)
    }

    private func launch(opening name: String = "plan.md") {
        var productsDirectory = Bundle(for: Self.self).bundleURL
        for _ in 0 ..< 4 {
            productsDirectory.deleteLastPathComponent()
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .forEach { $0.forceTerminate() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        configuration.environment = ["CFFIXED_USER_HOME": root.appendingPathComponent("home").path]
        let opened = expectation(description: "open")
        NSWorkspace.shared.open(
            [root.appendingPathComponent("ws/notes/\(name)")],
            withApplicationAt: productsDirectory.appendingPathComponent("Fen.app"),
            configuration: configuration
        ) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    /// Adds the `ws` folder through File > Workspaces… and returns the Workspaces window.
    private func addWorkspace() -> XCUIElement {
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["Workspaces…"].click()
        let predicate = NSPredicate(format: "title == 'Workspaces' OR identifier == 'workspaces'")
        let window = app.windows.matching(predicate).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let add = window.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add button:\n\(window.debugDescription)")
        add.click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(root.appendingPathComponent("ws").path + "\n")
        let open = panel.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(window.staticTexts["ws"].waitForExistence(timeout: 10))
        return window
    }

    func testSettingsSheetShowsEnrichControlsAndSearchScopesWork() {
        launch()
        let window = addWorkspace()

        // The row isn't "hittable" while the open panel animates away, so click by coordinate.
        window.outlineRows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        window.outlines.firstMatch.menus.menuItems["Settings…"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        let enrichOnSave = sheet.switches.firstMatch
        XCTAssertTrue(enrichOnSave.exists, "Enrich on save toggle is missing")
        XCTAssertTrue(enrichOnSave.isEnabled)
        XCTAssertEqual((enrichOnSave.value as? NSNumber)?.intValue, 0, "Enrich on save should be off by default")
        enrichOnSave.click()
        XCTAssertEqual((enrichOnSave.value as? NSNumber)?.intValue, 1)
        XCTAssertTrue(sheet.staticTexts["Enrich on a schedule"].exists, "schedule picker is missing")

        // Each sentence in the footer appears once.
        let footer = sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "None keeps this workspace"))
            .firstMatch
        XCTAssertTrue(footer.exists)
        let text = footer.value as? String ?? ""
        XCTAssertEqual(text.components(separatedBy: "A schedule does the same").count - 1, 1, text)

        sheet.buttons["Save"].firstMatch.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        let field = window.toolbars.searchFields.firstMatch
        field.click()
        field.typeText("pricing")
        let result = window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "plan.md")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "no result for pricing")

        // With no workspace chosen, Chosen Workspaces finds nothing. Choosing `ws` brings the result back.
        window.buttons["Search, Chosen Workspaces"].firstMatch.click()
        XCTAssertTrue(window.staticTexts["No workspaces chosen"].waitForExistence(timeout: 10))
        window.buttons.matching(NSPredicate(format: "label CONTAINS 'workspace' OR identifier == 'checklist'"))
            .firstMatch.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "chooser popover did not open")
        popover.checkBoxes["ws"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(result.waitForExistence(timeout: 20), "chosen workspace did not bring the result back")
    }

    /// A workspace still reads and searches after a relaunch. In the sandboxed App Store build this only
    /// works if the saved folder bookmark resumes (issue #40).
    func testWorkspaceKeepsWorkingAfterRelaunch() {
        launch()
        addWorkspace().typeKey("w", modifierFlags: .command)
        app.terminate()
        launch()
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["Workspaces…"].click()
        let window = app.windows.matching(NSPredicate(format: "title == 'Workspaces' OR identifier == 'workspaces'"))
            .firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["ws"].waitForExistence(timeout: 10), "the workspace was forgotten")
        let field = window.toolbars.searchFields.firstMatch
        field.click()
        field.typeText("pricing")
        let result = window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "plan.md")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "the workspace is gone after a relaunch")
    }

    /// The sandboxed App Store build has no listening socket, so Settings has no Agents tab (issue #40).
    /// Only `scripts/test-appstore-sandbox.sh` sets `FEN_SANDBOXED`.
    func testSettingsHasNoAgentsTabInTheSandbox() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FEN_SANDBOXED"] != nil, "needs the sandboxed build")
        launch()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title == 'Settings' OR title == 'General'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(settings.toolbars.buttons["AI"].waitForExistence(timeout: 5), settings.debugDescription)
        XCTAssertFalse(settings.toolbars.buttons["Agents"].exists, "the Agents tab is shown")
    }

    /// A file that is not open and links here with `[[plan]]` shows up under "Linked from" (issue #36).
    func testBacklinksPanelListsALinkingFileThatIsNotOpen() {
        launch()
        let workspaces = addWorkspace()
        workspaces.typeKey("w", modifierFlags: .command)
        let document = app.windows["plan.md"]
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.buttons["OutlineToggleButton"].click()
        let heading = document.staticTexts["Linked from"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "no Linked from heading:\n\(document.debugDescription)")
        XCTAssertTrue(document.buttons["Roadmap"].exists, "roadmap.md is not listed:\n\(document.debugDescription)")
    }

    /// File > Browse Version History… is enabled for a saved document and opens the system browser (issue #59).
    func testBrowseVersionHistoryOpens() {
        launch()
        let document = app.windows["plan.md"]
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuBars.menuItems["Browse Version History…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isEnabled)
        item.click()
        let restore = app.buttons["Restore"]
        XCTAssertTrue(
            restore.waitForExistence(timeout: 15) || app.buttons["Done"].exists,
            "no version browser:\n\(app.debugDescription)"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    /// A near-miss field name gets a hint, and Fix renames it in the editor (issue #7).
    func testPropertiesPanelHintFixesATypo() {
        launch(opening: "task.md")
        let workspaces = addWorkspace()
        workspaces.typeKey("w", modifierFlags: .command)
        let document = app.windows["task.md"]
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.buttons["OutlineToggleButton"].click()
        let title = document.staticTexts["Properties · Task"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no Properties panel:\n\(document.debugDescription)")
        let fix = document.buttons["Fix"]
        XCTAssertTrue(fix.waitForExistence(timeout: 5), "no hint:\n\(document.debugDescription)")
        // Closing the Workspaces window leaves this one without focus. A click in the editor gives it back.
        let editor = document.textViews.firstMatch
        editor.click()
        fix.click()
        let fixed = NSPredicate(format: "value CONTAINS 'status: done' AND NOT (value CONTAINS 'statsu')")
        expectation(for: fixed, evaluatedWith: editor)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(fix.waitForExistence(timeout: 2), "the hint stays after the fix")
    }

    /// The Activity sheet opens from the workspace header and closes with Done (issue #140).
    func testActivitySheetOpensAndCloses() {
        launch()
        let window = addWorkspace()
        window.outlineRows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let activity = window.buttons["Activity"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10), "no Activity button:\n\(window.debugDescription)")
        activity.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["No AI changes yet."].exists, sheet.debugDescription)
        sheet.buttons["Done"].firstMatch.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
}
