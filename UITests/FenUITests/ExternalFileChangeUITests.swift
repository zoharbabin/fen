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

    /// Force-terminates any previous instance and waits for it to actually exit, not just for the
    /// termination request to be posted -- a still-dying previous process can otherwise get
    /// coalesced with the "new" instance the next launch requests, or leave a stale window that
    /// collides with this test's own window-title lookup.
    private func terminateRunningInstancesAndWait() {
        func running() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        }
        running().forEach { $0.forceTerminate() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !running().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
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

        terminateRunningInstancesAndWait()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // macOS's own window-restoration (Resume) otherwise reopens whatever Fen windows were
        // left over from unrelated prior runs (including ordinary manual use as the default .md
        // handler) alongside the document this test opens -- see Apple Technical Q&A QA1544.
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
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
        // A literal "notes.md" collides with a same-named window macOS's own session restoration
        // can leave open from an earlier test run in this same app; a UUID-qualified name -- the
        // same approach every other UI test in this suite already uses -- makes the window title
        // this test looks up for unique to this run.
        let documentURL = directory.appendingPathComponent("notes-\(UUID().uuidString).md")
        try "original content".write(to: documentURL, atomically: true, encoding: .utf8)

        launch(fileURL: documentURL)

        let editor = documentWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "original content")

        try "changed from outside Fen".write(to: documentURL, atomically: true, encoding: .utf8)

        // Scoped to the alert's own AXDialog container, not app.buttons: AppKit mirrors every
        // NSAlert button onto the current Touch Bar too, and an unscoped query matches both.
        let reloadButton = app.dialogs.buttons["Reload"]
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
