import AppKit
import XCTest

/// Find (issue #255) through the real app: one bar for the editor, the preview and both side by side.
@MainActor
final class FindUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Same launch strategy as `FocusModeUITests.launch`.
    private func launch(text: String) {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("find-\(UUID()).md")
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        let productsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let appURL = productsDirectory.appendingPathComponent("Fen.app")
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .forEach { $0.forceTerminate() }
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
        documentWindow = app.windows[fileURL.lastPathComponent]
        XCTAssertTrue(documentWindow.waitForExistence(timeout: 5))
    }

    private var summary: XCUIElement {
        documentWindow.staticTexts["FindSummary"]
    }

    private func openFind(typing query: String) {
        app.typeKey("f", modifierFlags: .command)
        let field = documentWindow.textFields["FindField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Cmd+F should open the find bar")
        field.typeText(query)
    }

    private func waitForSummary(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
        let result = XCTWaiter().wait(
            for: [expectation(for: predicate, evaluatedWith: summary)], timeout: 5
        )
        XCTAssertEqual(result, .completed, "Expected the summary to read \(expected)", file: file, line: line)
    }

    private let note = "# Notes\n\nThe fen is wet.\n\nA second fen here.\n\nNo more FEN, but a third fen at the end.\n"

    func testSplitModeFindsInBothPanesAndEscClosesTheBar() {
        launch(text: note)
        openFind(typing: "fen")
        // Editor and preview each hold four matches, and the active pane's count shows.
        waitForSummary("1 of 4")
        app.typeKey(.return, modifierFlags: [])
        waitForSummary("2 of 4")
        app.typeKey(.return, modifierFlags: .shift)
        waitForSummary("1 of 4")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(documentWindow.groups["FindBar"].waitForNonExistence(timeout: 5))
    }

    func testPreviewOnlyModeFindsInThePreview() {
        launch(text: note)
        let picker = documentWindow.radioGroups["ViewModePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.radioButtons["Preview"].click()
        openFind(typing: "fen")
        waitForSummary("1 of 4")
        app.typeKey("g", modifierFlags: .command)
        waitForSummary("2 of 4")
        XCTAssertFalse(documentWindow.buttons["ReplaceAllButton"].exists, "Replace needs the editor")
    }

    func testEditorOnlyModeFindsAndReplaces() {
        launch(text: note)
        let picker = documentWindow.radioGroups["ViewModePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.radioButtons["Editor"].click()
        app.typeKey("f", modifierFlags: [.command, .option])
        let field = documentWindow.textFields["FindField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("fen")
        waitForSummary("1 of 4")
        let replacement = documentWindow.textFields["ReplaceField"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        replacement.click()
        replacement.typeText("owl")
        documentWindow.buttons["ReplaceAllButton"].click()
        waitForSummary("No results")
        let editorText = documentWindow.textViews.firstMatch.value as? String ?? ""
        XCTAssertFalse(editorText.localizedCaseInsensitiveContains("fen"))
        XCTAssertTrue(editorText.contains("owl"))
    }

    func testSingleMatchReadsOneOfOne() {
        launch(text: note)
        openFind(typing: "third")
        waitForSummary("1 of 1")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(documentWindow.groups["FindBar"].waitForNonExistence(timeout: 5))
    }
}
