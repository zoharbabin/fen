import AppKit
import CryptoKit
import XCTest

@MainActor
final class AutosaveUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

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

    /// Simulates a prior session that never exited cleanly by planting a recovery entry on disk
    /// directly, the same leftover state `AutosaveController.writeRecoveryFile` would leave
    /// behind -- computed via the same SHA-256-of-resolved-path identity the app itself uses, so
    /// a freshly launched app discovers it exactly as it would after a real unclean exit.
    private func plantRecoveryEntry(forFileAt fileURL: URL, recoveredText: String) throws {
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(resolved.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            XCTFail("no Application Support directory available in this environment")
            return
        }
        let recoveryDirectory = base.appendingPathComponent("Fen", isDirectory: true).appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let recoveryURL = recoveryDirectory.appendingPathComponent("path-\(hex).recovery")
        try recoveredText.write(to: recoveryURL, atomically: true, encoding: .utf8)
    }

    private func attachScreenshot(named name: String) {
        let screenshot = documentWindow.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOpeningADocumentWithALeftoverRecoveryEntryOffersToRestoreIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        try "saved content".write(to: documentURL, atomically: true, encoding: .utf8)
        try plantRecoveryEntry(forFileAt: documentURL, recoveredText: "unsaved recovered text")

        launch(fileURL: documentURL)

        let restoreButton = app.buttons["Restore"]
        XCTAssertTrue(
            restoreButton.waitForExistence(timeout: 10),
            "Expected the recovery alert's Restore button to appear"
        )
        attachScreenshot(named: "autosave-restore-alert")
        restoreButton.click()

        let editor = documentWindow.scrollViews["EditorTextView"].textViews.firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, editor.value as? String != "unsaved recovered text" {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(editor.value as? String, "unsaved recovered text")
    }
}
