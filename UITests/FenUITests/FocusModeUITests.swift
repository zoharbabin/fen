import AppKit
import XCTest

/// E2E proof for issue #19 (github.com/zoharbabin/fen/issues/19), harness gate 6: exercises
/// focus/typewriter mode through the real app rather than asserting on Coordinator internals.
@MainActor
final class FocusModeUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Same launch strategy as `FormattingToolbarUITests.launch` -- opens a real file from this
    /// test bundle's sibling app build, in a freshly launched process. `extraArguments` lets
    /// callers override a persisted preference for just this launched process via macOS's
    /// `NSArgumentDomain`, the same technique `EditorGutterUITests.launch` uses for
    /// `editorShowLineNumbers` -- so rule 2.1's independent dim/center preferences (issue #127)
    /// can be exercised without a toolbar/Settings round trip.
    private func launch(fileURL: URL, extraArguments: [String] = []) {
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
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"] + extraArguments
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

    private func launchWithFreshDocument(text: String, extraArguments: [String] = []) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focus-mode-\(UUID()).md")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        launch(fileURL: tempURL, extraArguments: extraArguments)
    }

    private func editorScrollPercent() -> Int? {
        let editor = documentWindow.scrollViews["EditorTextView"]
        guard let value = editor.value as? String else { return nil }
        return Int(value.replacingOccurrences(of: "%", with: ""))
    }

    /// Rule 4.4/4.5 (issue #19): enabling focus mode and moving the caret to a paragraph far
    /// below the fold recenters the editor's scroll position -- proving the real scroll view
    /// actually moved, not just that some internal offset was computed.
    func testEnablingFocusModeAndMovingCaretRecentersTheEditor() {
        let paragraphs = (1 ... 60).map { "Paragraph \($0) of the document with enough text to take up a full line." }
        launchWithFreshDocument(text: paragraphs.joined(separator: "\n\n"))

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        let toggleButton = documentWindow.buttons["FocusModeToggleButton"]
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))
        toggleButton.click()

        let scrollBefore = editorScrollPercent()

        // Move the caret to the very end of the document, several screens below the fold --
        // typewriter recentering should scroll the editor to keep the caret's line centered.
        editor.textViews.firstMatch.click()
        editor.typeKey(.downArrow, modifierFlags: .command)

        let deadline = Date().addingTimeInterval(5)
        var scrollAfter = editorScrollPercent()
        while Date() < deadline, scrollAfter == scrollBefore {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            scrollAfter = editorScrollPercent()
        }

        attachScreenshot(named: "focus-mode-typewriter-recenter")

        XCTAssertNotEqual(
            scrollBefore, scrollAfter,
            "Moving the caret to the end of a long document with focus mode on should recenter the editor's scroll position"
        )
    }

    /// Rule 2.2 (issue #127): with `editorFocusModeCentersCaret` off, moving the caret to a
    /// mid-document line lands the editor's scroll at a materially different position than with
    /// it on -- proving the two preferences drive genuinely independent behavior, not just
    /// independent storage. Compares two full launches (one per preference value) rather than a
    /// single "scroll changed / didn't change" check against a fixed threshold: moving the caret
    /// to a mid-document line still requires *some* scroll either way once it's below the fold
    /// (NSTextView's own "reveal the caret" behavior versus this preference's deliberate
    /// centering), so the discriminator is which position the scroll settles at, not whether it
    /// moves at all -- the same reasoning that ruled out reusing the sibling recentering test's
    /// cmd+End move here, since jumping to the document's literal last line clamps both
    /// behaviors to the same maximum scroll offset and can't tell them apart.
    func testDisablingCentersCaretPreferenceLandsAtADifferentScrollPositionThanCentering() {
        let paragraphs = (1 ... 200).map { "Paragraph \($0) of the document with enough text to take up a full line." }
        let text = paragraphs.joined(separator: "\n\n")

        func scrollPercentAfterMovingCaretMidDocument(focusModeEnabled: Bool, centersCaret: Bool) -> Int? {
            // Always passes both arguments explicitly (never omits one to fall back on the
            // in-code default) -- `Preferences`' `didSet` persists whatever value it reads at
            // init, including one supplied only via `NSArgumentDomain`, into
            // `com.zoharbabin.fen`'s real persistent defaults shared across every launch of this
            // bundle identifier. Without `-editorFocusModeEnabled` pinned every time, the
            // toolbar button below -- which toggles rather than sets -- would flip from
            // whatever an earlier launch in this same test left persisted, not from the state
            // this run's `focusModeEnabled` parameter actually asks for.
            let extraArguments = [
                "-editorFocusModeCentersCaret", centersCaret ? "YES" : "NO",
                "-editorFocusModeEnabled", "NO",
            ]
            launchWithFreshDocument(text: text, extraArguments: extraArguments)

            let editor = documentWindow.scrollViews["EditorTextView"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))

            if focusModeEnabled {
                let toggleButton = documentWindow.buttons["FocusModeToggleButton"]
                XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))
                toggleButton.click()
            }

            editor.textViews.firstMatch.click()
            editor.typeKey(.upArrow, modifierFlags: .command) // start from a known position: document start
            for _ in 0 ..< 200 {
                editor.typeKey(.downArrow, modifierFlags: [])
            }

            let deadline = Date().addingTimeInterval(5)
            var scroll = editorScrollPercent()
            while Date() < deadline, scroll == nil {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                scroll = editorScrollPercent()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            return editorScrollPercent()
        }

        let focusModeOffPercent = scrollPercentAfterMovingCaretMidDocument(focusModeEnabled: false, centersCaret: true)
        let centeringDisabledPercent = scrollPercentAfterMovingCaretMidDocument(
            focusModeEnabled: true, centersCaret: false
        )
        let centeringEnabledPercent = scrollPercentAfterMovingCaretMidDocument(
            focusModeEnabled: true, centersCaret: true
        )

        attachScreenshot(named: "focus-mode-centers-caret-disabled")

        XCTAssertEqual(
            focusModeOffPercent,
            centeringDisabledPercent,
            "Expected disabling editorFocusModeCentersCaret to scroll identically to focus mode being off entirely"
        )
        XCTAssertNotEqual(
            focusModeOffPercent,
            centeringEnabledPercent,
            "Expected focus mode's caret centering to scroll differently than focus mode being off"
        )
    }

    /// Rule 3.5 (issue #19): toggling focus mode off and back on, and continuing to type,
    /// never leaves the editor unresponsive or the toggle button unreachable -- a basic
    /// end-to-end smoke test of the real toggle flow a user drives from the toolbar.
    func testTogglingFocusModeOnAndOffKeepsEditorResponsive() {
        launchWithFreshDocument(text: "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")

        let editor = documentWindow.scrollViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        let toggleButton = documentWindow.buttons["FocusModeToggleButton"]
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))

        toggleButton.click()
        toggleButton.click()

        let textView = editor.textViews.firstMatch
        textView.click()
        textView.typeKey(.end, modifierFlags: .command)
        app.typeText(" appended after toggling focus mode twice.")

        let deadline = Date().addingTimeInterval(5)
        var value = textView.value as? String
        while Date() < deadline, value?.contains("appended after toggling") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            value = textView.value as? String
        }

        attachScreenshot(named: "focus-mode-toggle-twice")

        XCTAssertTrue(
            value?.contains("appended after toggling") == true,
            "The editor should remain fully responsive to typing after toggling focus mode off and back on"
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
