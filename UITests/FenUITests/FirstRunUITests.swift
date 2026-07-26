import AppKit
import XCTest

/// E2E proof for issue #37, harness gate 6: wipes app state to simulate a genuine fresh install,
/// launches the real built app, and asserts the very first document opened is the bundled welcome
/// document -- not `FirstRunContent` called directly (that's `FirstRunTests`/`FirstRunIsolationTests`
/// in `Tests/FenTests`). A second new document created afterward must be blank.
@MainActor
final class FirstRunUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - Launch helpers (same strategy as DefaultEditorUITests)

    private func appURL() throws -> URL {
        let productsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // FenMacOSUITests-Runner.app
            .deletingLastPathComponent() // Debug
        let url = productsDirectory.appendingPathComponent("Fen.app")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Expected the built app under test at \(url.path)"
        )
        return url
    }

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

    /// Deletes any prior app state so the next launch is a genuine fresh-install first launch --
    /// same paths as `DefaultEditorUITests.wipeAppDataContainer()` (issue #14 rule 9.3), since
    /// `hasCompletedFirstRun` (issue #37) lives in the same preferences plist that rule already
    /// wipes.
    private func wipeAppDataContainer() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent("Library/Preferences/com.zoharbabin.fen.plist"),
            home.appendingPathComponent("Library/Saved Application State/com.zoharbabin.fen.savedState"),
            home.appendingPathComponent("Library/Containers/com.zoharbabin.fen"),
            home.appendingPathComponent(
                "Library/Application Support/com.apple.sharedfilelist/" +
                    "com.apple.LSSharedFileList.ApplicationRecentDocuments/com.zoharbabin.fen.sfl4"
            ),
        ]
        for path in paths {
            try? fileManager.removeItem(at: path)
        }
    }

    private func launchBare() throws {
        terminateRunningInstancesAndWait()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let openedExpectation = expectation(description: "Fen launched")
        let url = try appURL()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            XCTAssertNil(error)
            openedExpectation.fulfill()
        }
        wait(for: [openedExpectation], timeout: 10)

        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    private func attachScreenshot(named name: String, of window: XCUIElement) {
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Rule 4.1/5.1: a genuine fresh install opens the bundled welcome document, then blank

    func testFreshInstallOpensWelcomeDocumentThenSecondDocumentIsBlank() throws {
        // Order matters: terminate before wiping, not after -- a still-alive previous instance can
        // otherwise rewrite the saved-state/prefs files this wipe deletes before it exits.
        terminateRunningInstancesAndWait()
        wipeAppDataContainer()

        try launchBare()

        // Same environment-dependent fork DefaultEditorUITests observes for rule 9.3: a genuinely
        // fresh data container can surface the "Untitled" document directly, or SwiftUI's
        // document-browser "Open" panel first.
        if app.windows["Open"].waitForExistence(timeout: 5) {
            let newDocumentButton = app.windows["Open"].buttons["New Document"]
            XCTAssertTrue(newDocumentButton.waitForExistence(timeout: 5))
            newDocumentButton.click()
        }

        let firstWindow = app.windows["Untitled"]
        XCTAssertTrue(
            firstWindow.waitForExistence(timeout: 5),
            "Expected a fresh launch to open an \"Untitled\" document"
        )

        let firstEditor = firstWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(firstEditor.waitForExistence(timeout: 5))
        let firstText = try firstEditorText(firstEditor)
        XCTAssertTrue(
            firstText.contains("# Welcome to Fen"),
            "Expected the first document on a fresh install to be the bundled welcome document, got: \(firstText)"
        )
        attachScreenshot(named: "first-run-welcome-document", of: firstWindow)

        app.typeKey("n", modifierFlags: .command)
        let secondWindow = app.windows["Untitled 2"]
        XCTAssertTrue(
            secondWindow.waitForExistence(timeout: 5),
            "Expected Cmd+N to open a second untitled document window"
        )
        let secondEditor = secondWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(secondEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(
            (secondEditor.value as? String) ?? "",
            "",
            "Expected the second new document to be blank now that first run has completed"
        )
        attachScreenshot(named: "first-run-second-document-blank", of: secondWindow)
    }

    /// Polls briefly since the editor's accessibility value can lag one runloop turn behind the
    /// document actually finishing its open -- same pattern as `AutosaveUITests`' recovery poll.
    private func firstEditorText(_ editor: XCUIElement) throws -> String {
        let deadline = Date().addingTimeInterval(5)
        var text = (editor.value as? String) ?? ""
        while Date() < deadline, text.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            text = (editor.value as? String) ?? ""
        }
        return text
    }
}
