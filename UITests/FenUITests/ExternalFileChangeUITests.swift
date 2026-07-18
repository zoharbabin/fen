import AppKit
import XCTest

/// E2E proof for issue #20, harness gate 6 (manual/UI verification pass): writes to a real
/// document's file from outside the app process, then asserts the real reload/keep-mine alert
/// appears in the actual running app and that clicking "Reload" replaces the real editor's text --
/// not on `ExternalChangeController` called directly (that's `ExternalFileChangeVerifyTest` in
/// `Tests/FenTests`).
@MainActor
final class ExternalFileChangeUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// Same launch strategy as `ImagePasteUITests.launch`.
    private func launch(fileURL: URL) {
        let productsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // FenMacOSUITests-Runner.app
            .deletingLastPathComponent() // Debug
        let appURL = productsDirectory.appendingPathComponent("Fen.app")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appURL.path),
            "Expected the built app under test at \(appURL.path)"
        )

        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .forEach { $0.forceTerminate() }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let openedExpectation = expectation(description: "Fen opened \(fileURL.lastPathComponent)")
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration) { _, error in
            XCTAssertNil(error)
            openedExpectation.fulfill()
        }
        wait(for: [openedExpectation], timeout: 10)

        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let windowTitle = fileURL.lastPathComponent
        documentWindow = app.windows[windowTitle]
        XCTAssertTrue(documentWindow.waitForExistence(timeout: 5), "Expected a window titled \(windowTitle)")
    }

    private func attachScreenshot(named name: String) {
        let screenshot = documentWindow.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Rule 5.2/3.1 (issue #20): a real write to the document's file from a second, independent
    /// process (`FileManager.default.createFile`, not through the running app at all) fires the
    /// real reload alert, and choosing Reload replaces the real editor's real text.
    func testExternalWriteWhileAppIsOpenShowsReloadAlertAndReloadReplacesText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalFileChangeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        try "original content".write(to: documentURL, atomically: true, encoding: .utf8)

        launch(fileURL: documentURL)

        let editor = documentWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "original content")

        try "changed from outside Fen".write(to: documentURL, atomically: true, encoding: .utf8)

        let reloadButton = app.buttons["Reload"]
        XCTAssertTrue(reloadButton.waitForExistence(timeout: 10), "Expected the reload alert's Reload button to appear")
        attachScreenshot(named: "external-change-reload-alert")
        reloadButton.click()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, editor.value as? String != "changed from outside Fen" {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(editor.value as? String, "changed from outside Fen")
    }
}
