import AppKit
import XCTest

/// E2E proof for issue #21 (github.com/zoharbabin/fen/issues/21), harness gate 6: exercises the
/// real editor gutter through the real app rather than asserting on `NSLayoutManager` internals
/// (already covered by `EditorGutterTests`) or `WKWebView` JS state (already covered by
/// `PreviewGutterVerifyTest`) in isolation.
@MainActor
final class EditorGutterUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// Same launch strategy as `FocusModeUITests.launch`, plus an `-editorShowLineNumbers YES`
    /// argument -- macOS's `NSArgumentDomain` overrides the persisted preference for just this
    /// launched process, so the gutter preference doesn't need a toolbar/Settings round trip
    /// (there is no toolbar toggle for it, unlike focus mode) and no state leaks to other tests.
    private func launch(fileURL: URL, showLineNumbers: Bool) {
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
        // macOS's own window-restoration (Resume) otherwise reopens whatever Fen windows were
        // left over from an earlier test run alongside the document this test opens, and one of
        // those leftover windows can carry an unsaved-changes autosave prompt that steals
        // keyboard focus mid-test -- see Apple Technical Q&A QA1544, and DefaultEditorUITests'
        // identical fix for the same failure mode.
        configuration.arguments = [
            "-editorShowLineNumbers", showLineNumbers ? "YES" : "NO",
            "-ApplePersistenceIgnoreState", "YES",
        ]
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

    private func launchWithFreshDocument(text: String, showLineNumbers: Bool) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("editor-gutter-\(UUID()).md")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        launch(fileURL: tempURL, showLineNumbers: showLineNumbers)
    }

    /// Rule 1.2/2.1 (issue #21): the ruler view (macOS gutter) only appears once the preference
    /// is on -- proven via `NSScrollView.rulersVisible`/`hasVerticalRuler`, the real AppKit state
    /// `installGutterRulerView` toggles, not just that no crash occurred.
    func testGutterHiddenByDefaultAndVisibleWhenPreferenceEnabled() {
        launchWithFreshDocument(text: "First line\nSecond line\nThird line", showLineNumbers: false)

        let editorOff = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editorOff.waitForExistence(timeout: 5))
        XCTAssertEqual(
            editorOff.children(matching: .ruler).count, 0,
            "Expected no ruler view when editorShowLineNumbers is off"
        )
        attachScreenshot(named: "editor-gutter-disabled")
        app.terminate()

        launchWithFreshDocument(text: "First line\nSecond line\nThird line", showLineNumbers: true)
        let editorOn = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editorOn.waitForExistence(timeout: 5))

        let deadline = Date().addingTimeInterval(5)
        var rulerCount = editorOn.children(matching: .ruler).count
        while Date() < deadline, rulerCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            rulerCount = editorOn.children(matching: .ruler).count
        }
        attachScreenshot(named: "editor-gutter-enabled")
        XCTAssertGreaterThan(rulerCount, 0, "Expected a ruler view once editorShowLineNumbers is on")
    }

    /// Rule 3.x (issue #21): typing more lines into a long, mixed-content document keeps the
    /// editor responsive with the gutter on, and the app doesn't crash while scrolling through
    /// wrapped paragraphs, a code fence, and a table -- the real end-to-end flow the acceptance
    /// criteria's "long, mixed-content document on both macOS and iOS" check calls for.
    func testGutterRemainsStableWhileScrollingMixedContentDocument() {
        var lines = [String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)]
        lines.append("")
        lines.append("```swift")
        lines.append("let x = 1")
        lines.append("```")
        lines.append("")
        lines.append("| A | B |")
        lines.append("| - | - |")
        lines.append("| 1 | 2 |")
        for i in 1 ... 20 {
            lines.append("")
            lines.append("## Heading \(i)")
        }
        launchWithFreshDocument(text: lines.joined(separator: "\n"), showLineNumbers: true)

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.textViews.firstMatch.click()

        editor.scroll(byDeltaX: 0, deltaY: -800)
        editor.typeText(" appended while scrolled.")

        let textView = editor.textViews.firstMatch
        let deadline = Date().addingTimeInterval(5)
        var value = textView.value as? String
        while Date() < deadline, value?.contains("appended while scrolled") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            value = textView.value as? String
        }

        attachScreenshot(named: "editor-gutter-mixed-content-scrolled")
        XCTAssertTrue(
            value?.contains("appended while scrolled") == true,
            "The editor should remain responsive to typing while scrolled with the gutter enabled"
        )
        XCTAssertTrue(app.exists, "Fen should not have crashed while scrolling a mixed-content document")
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
