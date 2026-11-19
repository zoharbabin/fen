import AppKit
import XCTest

/// Issue #258: opens a document with a pandoc grid table in the real app and checks the
/// preview shows the notice, with the original table text still visible.
@MainActor
final class GridTableNoticeUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private static let notice = "This is a pandoc grid table. Fen renders GFM pipe tables only."
    private var app: XCUIApplication!
    private var fileURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fen-grid-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("grid-table-notice.md")
        let markdown = """
        # Day 1

        Before the table.

        +-------+--------------------------+-------------+
        | Time  | Session                  | Format      |
        +=======+==========================+=============+
        | 09:30 | Arrival, coffee and      | 30 min      |
        |       | breakfast                |             |
        +-------+--------------------------+-------------+

        After the table.

        | Time | Session |
        |------|---------|
        | 10:00 | A pipe table still renders |
        """
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testPreviewShowsTheNoticeAndKeepsTheTableText() {
        // The app under test is the sibling of this test bundle's runner, not whatever Launch
        // Services finds (same approach as ScrollSyncUITests).
        let productsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // FenMacOSUITests-Runner.app
            .deletingLastPathComponent() // Debug
        let appURL = productsDirectory.appendingPathComponent("Fen.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path), "Expected \(appURL.path)")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let opened = expectation(description: "Fen opened the file")
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)

        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let window = app.windows["grid-table-notice.md"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let preview = window.otherElements["PreviewWebView"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let notice = window.staticTexts[Self.notice]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "The preview should show the grid table notice")

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "grid-table-notice"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: window.debugDescription)
        tree.name = "window-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        // The editor pane is a text view, so a static text starting with the border is the
        // preview's `<pre>`. The pipe table below it must still render as a real table.
        let source = window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "+-------+")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), "The table text should stay visible under the notice")
        XCTAssertTrue(window.tables.firstMatch.waitForExistence(timeout: 5), "A pipe table should still render")
    }
}
