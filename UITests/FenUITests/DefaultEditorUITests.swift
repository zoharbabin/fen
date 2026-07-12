import AppKit
import XCTest

/// E2E proof for issue #14 (github.com/zoharbabin/fen/issues/14), harness gate 6: exercises
/// Open Recent (rule 9.1), missing-file omission (rule 9.2 / cross-referenced resiliency rule
/// 3.1), and first launch (rule 9.3) through the real app rather than asserting on
/// `NSDocumentController` state directly.
@MainActor
final class DefaultEditorUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - Launch helpers (same strategy as DocumentOutlineUITests/FormattingToolbarUITests)

    /// This test bundle lands at .../Debug/FenMacOSUITests-Runner.app/Contents/PlugIns/FenMacOSUITests.xctest;
    /// the app under test is its sibling at .../Debug/Fen.app.
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

    /// Opens `fileURL` (or nothing, for a bare launch) in a freshly launched instance of the app
    /// under test, force-terminating any previous instance first. Waits for the document's own
    /// window to exist (when `fileURL` is given) before returning -- `NSDocumentController`
    /// only records a URL as "recently opened" once the document has actually finished opening,
    /// so a caller that force-terminates the next instance too early (before that registration
    /// lands) would race Open Recent's own bookkeeping.
    private func launch(fileURL: URL?) throws {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .forEach { $0.forceTerminate() }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let openedExpectation = expectation(description: "Fen launched")
        let url = try appURL()
        if let fileURL {
            NSWorkspace.shared.open([fileURL], withApplicationAt: url, configuration: configuration) { _, error in
                XCTAssertNil(error)
                openedExpectation.fulfill()
            }
        } else {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                XCTAssertNil(error)
                openedExpectation.fulfill()
            }
        }
        wait(for: [openedExpectation], timeout: 10)

        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        if let fileURL {
            let documentWindow = app.windows[fileURL.lastPathComponent]
            XCTAssertTrue(
                documentWindow.waitForExistence(timeout: 10),
                "Expected a window titled \(fileURL.lastPathComponent) after opening it"
            )
        }
    }

    /// Quits the running instance via Cmd+Q (the real user path for "quit", which is what rule
    /// 9.1 needs to prove recents survive a real quit/relaunch cycle) rather than
    /// `XCUIApplication.terminate()`, which sends SIGTERM directly and skips the app's own quit
    /// handling.
    private func quitViaMenu() {
        app.typeKey("q", modifierFlags: .command)
        _ = app.wait(for: .notRunning, timeout: 10)
    }

    /// Drives File > Open Recent open and returns its submenu's items. Structure confirmed via
    /// manual AppleScript/System Events exploration of the real menu bar: menu bar item "File" >
    /// its menu > menu item "Open Recent" > that item's own submenu.
    private func openRecentMenuItems() -> [XCUIElement] {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5))
        let fileMenuBarItem = menuBar.menuBarItems["File"]
        XCTAssertTrue(fileMenuBarItem.waitForExistence(timeout: 5))
        fileMenuBarItem.click()

        let openRecentItem = fileMenuBarItem.menus.menuItems["Open Recent"]
        XCTAssertTrue(openRecentItem.waitForExistence(timeout: 5), "Expected a File > Open Recent menu item")
        openRecentItem.click()

        let submenu = openRecentItem.menus.firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 5), "Expected Open Recent to expand a submenu")
        return submenu.menuItems.allElementsBoundByIndex
    }

    private func makeTempMarkdownFile(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID()).md")
        try "# \(name)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Deletes any prior app state (preferences, saved window state, container, LaunchServices
    /// recents) so the next launch is a genuine fresh-install first launch, per rule 9.3.
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

    /// Records visible proof of the flow for harness gate 6, attached to the test result.
    private func attachScreenshot(named name: String) {
        guard let window = app.windows.allElementsBoundByIndex.first else { return }
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Rule 9.1: Open Recent lists recently opened documents, most-recent-first, after quit/relaunch

    func testOpenRecentListsDocumentsMostRecentFirstAfterQuitAndRelaunch() throws {
        let docA = try makeTempMarkdownFile(name: "recent-a")
        let docB = try makeTempMarkdownFile(name: "recent-b")

        try launch(fileURL: docA)
        try launch(fileURL: docB) // force-terminates A's instance; LaunchServices' recents survive independently of the
        // app process

        quitViaMenu()
        try launch(fileURL: nil)

        let items = openRecentMenuItems().map(\.title)
        attachScreenshot(named: "open-recent-most-recent-first")

        let indexA = items.firstIndex(of: docA.lastPathComponent)
        let indexB = items.firstIndex(of: docB.lastPathComponent)
        XCTAssertNotNil(indexA, "Expected \(docA.lastPathComponent) in Open Recent after relaunch")
        XCTAssertNotNil(indexB, "Expected \(docB.lastPathComponent) in Open Recent after relaunch")
        if let indexA, let indexB {
            let message = "The most recently opened document (\(docB.lastPathComponent)) " +
                "should appear before \(docA.lastPathComponent)"
            XCTAssertLessThan(indexB, indexA, message)
        }
    }

    // MARK: - Rule 9.2 / 3.1: a recent entry whose file was deleted is silently omitted

    func testDeletedRecentFileIsOmittedWithoutAffectingOtherEntries() throws {
        let docKept = try makeTempMarkdownFile(name: "kept")
        let docDeleted = try makeTempMarkdownFile(name: "deleted")

        try launch(fileURL: docKept)
        try launch(fileURL: docDeleted)

        try FileManager.default.removeItem(at: docDeleted)

        quitViaMenu()
        try launch(fileURL: nil)

        let items = openRecentMenuItems().map(\.title)
        attachScreenshot(named: "open-recent-deleted-file-omitted")

        XCTAssertTrue(
            items.contains(docKept.lastPathComponent),
            "Expected \(docKept.lastPathComponent) to remain in Open Recent"
        )
        XCTAssertFalse(
            items.contains(docDeleted.lastPathComponent),
            "Expected the deleted file's entry to be silently omitted from Open Recent"
        )
    }

    // MARK: - Rule 9.3: a fresh launch (no prior session) opens a sensible new empty document

    func testFreshLaunchOpensANewEmptyDocumentNotACrashOrBlankWindow() throws {
        wipeAppDataContainer()

        try launch(fileURL: nil)

        // Empirically, a genuinely fresh data container can surface either the "Untitled" empty
        // document directly, or (observed on macOS 26 in this environment) SwiftUI's
        // document-browser "Open" panel first -- both are legitimate non-crash, non-blank
        // outcomes. The "Open" panel's own "New Document" button is the direct path to the same
        // empty document rule 9.3 requires, so drive it if it appears.
        if app.windows["Open"].waitForExistence(timeout: 5) {
            let newDocumentButton = app.windows["Open"].buttons["New Document"]
            XCTAssertTrue(newDocumentButton.waitForExistence(timeout: 5))
            newDocumentButton.click()
        }

        let untitledWindow = app.windows["Untitled"]
        XCTAssertTrue(
            untitledWindow.waitForExistence(timeout: 5),
            "Expected a fresh launch to end at a new empty (\"Untitled\") document"
        )
        attachScreenshot(named: "fresh-launch-untitled-document")
    }
}
