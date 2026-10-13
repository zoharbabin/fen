import AppKit
import XCTest

/// A Markdown file in iCloud Drive, opened and saved in the real app (issue #59). It uses your real
/// home and iCloud account, so it only runs when you point it at a file:
/// `TEST_RUNNER_FEN_ICLOUD_FILE=~/Library/Mobile\ Documents/com~apple~CloudDocs/test-file.md xcodebuild test ...`.
/// The run writes a marker line into the file. `scripts/check-icloud-file.swift` reads the file from
/// a terminal, checks versions and upload state, and puts the original text back.
@MainActor
final class ICloudDocumentUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testSaveInICloudDriveCreatesAVersionAndSyncs() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FEN_ICLOUD_FILE"]?.isEmpty == false,
            "Set TEST_RUNNER_FEN_ICLOUD_FILE to a file in iCloud Drive."
        )
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["FEN_ICLOUD_FILE"])
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        XCTAssertTrue(file.path.contains("com~apple~CloudDocs"), "That file is not in iCloud Drive.")
        let marker = "fen-icloud-check-\(UUID().uuidString.prefix(8))"

        var products = Bundle(for: Self.self).bundleURL
        for _ in 0 ..< 4 {
            products.deleteLastPathComponent()
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .forEach { $0.forceTerminate() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let opened = expectation(description: "open")
        NSWorkspace.shared.open(
            [file],
            withApplicationAt: products.appendingPathComponent("Fen.app"),
            configuration: configuration
        ) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let window = app.windows[file.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: 15), app.debugDescription)

        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\n\n\(marker)\n")
        app.typeKey("s", modifierFlags: .command)

        // The test runner can't read iCloud Drive (macOS privacy), so Fen's own UI is the witness.
        let typed = NSPredicate(format: "value CONTAINS %@", marker)
        expectation(for: typed, evaluatedWith: editor)
        waitForExpectations(timeout: 10)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3), "a save prompt appeared")

        app.menuBars.menuBarItems["File"].click()
        let item = app.menuBars.menuItems["Browse Version History…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isEnabled)
        item.click()
        let restore = app.buttons["Restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 15) || app.buttons["Done"].exists, app.debugDescription)
        print("ICLOUD marker \(marker)")
        app.typeKey(.escape, modifierFlags: [])
    }
}
