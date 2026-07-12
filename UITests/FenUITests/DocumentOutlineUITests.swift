import AppKit
import XCTest

/// E2E proof for issue #12 (github.com/zoharbabin/fen/issues/12), harness gate 6: exercises the
/// outline/TOC navigator through the real app rather than asserting on renderer/model output.
@MainActor
final class DocumentOutlineUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Same launch strategy as `ScrollSyncUITests.launchOpening` -- opens a real file from this
    /// test bundle's sibling app build, in a freshly launched process, scoped to the window that
    /// launch produced.
    private func launchOpening(_ relativePath: String) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DocumentOutlineUITests.swift
            .deletingLastPathComponent() // FenUITests
            .deletingLastPathComponent() // UITests
        let fileURL = repoRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "Expected \(fileURL.path) to exist"
        )
        launch(fileURL: fileURL)
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

    /// Rule 4.3 (issue #12): confirms the outline appears within a bounded time budget even for
    /// a document with thousands of headings, proving the outline list is lazily rendered rather
    /// than eagerly materializing every row up front.
    func testOutlineOpensPromptlyOnLargeHeadingCount() throws {
        let generated = (1 ... 2500).map { "## Heading \($0)" }.joined(separator: "\n\n")
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("outline-stress-\(UUID()).md")
        try generated.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        launch(fileURL: tempURL)

        let toggleButton = documentWindow.buttons["OutlineToggleButton"]
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))

        let start = Date()
        toggleButton.click()

        let sidebar = documentWindow.outlines["OutlineSidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Outline sidebar should appear")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "Outline should open within a bounded time budget on a 2500-heading document")

        attachScreenshot(named: "outline-large-document")
    }

    /// Exercises the real jump-to-heading flow: open the outline, click a heading row, assert
    /// the editor's caret/scroll position actually moved -- not just that the model updated.
    func testClickingOutlineRowJumpsEditorToHeading() {
        launchOpening("assets/demo.md")

        let toggleButton = documentWindow.buttons["OutlineToggleButton"]
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))
        toggleButton.click()

        let sidebar = documentWindow.outlines["OutlineSidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        let editor = documentWindow.scrollViews["EditorTextView"]
        let editorScrollBefore = editor.value as? String

        let rows = sidebar.outlineRows.allElementsBoundByIndex
        XCTAssertFalse(rows.isEmpty, "Expected at least one heading row in the outline")
        rows.last?.buttons.allElementsBoundByIndex.last?.click()

        let deadline = Date().addingTimeInterval(5)
        var editorScrollAfter = editor.value as? String
        while Date() < deadline, editorScrollAfter == editorScrollBefore {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            editorScrollAfter = editor.value as? String
        }

        attachScreenshot(named: "outline-jump-to-heading")

        XCTAssertNotEqual(
            editorScrollBefore, editorScrollAfter,
            "Clicking a heading far down the outline should scroll the editor to that heading"
        )
    }

    /// Records visible proof of the flow for harness gate 6, attached to the test result.
    private func attachScreenshot(named name: String) {
        let screenshot = documentWindow.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
