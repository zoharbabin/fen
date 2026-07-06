import AppKit
import XCTest

@MainActor
final class ScrollSyncUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var documentWindow: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Opens a real file the same way Finder's double-click or `open -a Fen
    /// file.md` would, so scroll-sync is exercised against documents this
    /// repo already maintains for other purposes (`assets/demo.md`,
    /// `assets/image-formats-test.md`) instead of synthetic text typed
    /// into a blank document. Those real files carry organic density
    /// variance — headers, tables, fenced code, Mermaid source, images —
    /// that hand-written test fixtures don't naturally reproduce.
    ///
    /// Resolves the app bundle from this test bundle's own location rather
    /// than `NSWorkspace.urlForApplication(withBundleIdentifier:)`, which
    /// goes through Launch Services and can resolve to an unrelated
    /// installed copy (e.g. `/Applications/Fen.app`) instead of the one
    /// just built for this test run.
    private func launchOpening(_ relativePath: String) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ScrollSyncUITests.swift
            .deletingLastPathComponent() // FenUITests
            .deletingLastPathComponent() // UITests
        let fileURL = repoRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "Expected \(fileURL.path) to exist"
        )

        // This test bundle lands at .../Debug/FenMacOSUITests-Runner.app/Contents/PlugIns/FenMacOSUITests.xctest;
        // the app under test is its sibling at .../Debug/Fen.app.
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

        // Ensure the file opens in a freshly launched instance of the app
        // under test, not a preexisting one from an earlier run.
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .forEach { $0.forceTerminate() }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let openedExpectation = expectation(description: "Fen opened \(relativePath)")
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration) { _, error in
            XCTAssertNil(error)
            openedExpectation.fulfill()
        }
        wait(for: [openedExpectation], timeout: 10)

        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        // Fen's DocumentGroup app reuses one process for every open document window, so a
        // window left over from another test (or a manual launch) can outlive this one and make
        // an app-wide element query match more than once. Scope to the window that was just
        // opened, identified by its title bar showing this file's name.
        let windowTitle = (relativePath as NSString).lastPathComponent
        documentWindow = app.windows[windowTitle]
        XCTAssertTrue(documentWindow.waitForExistence(timeout: 5), "Expected a window titled \(windowTitle)")
    }

    /// The accessibility identifiers in `SplitEditorView` land on the
    /// SwiftUI wrapper elements (an `NSScrollView` for the editor, a `Group`
    /// for the WKWebView-backed preview), not on the native `TextView`/
    /// `WebView` roles — so look those up, then descend for interaction.
    private func editorContainer() -> XCUIElement {
        documentWindow.scrollViews["EditorTextView"]
    }

    private func previewContainer() -> XCUIElement {
        documentWindow.otherElements["PreviewWebView"]
    }

    /// Reads the `NN%` accessibility value exposed by `SplitEditorView` for
    /// the given pane, driven directly by the live `ScrollSync` state.
    ///
    /// The preview pane wraps a native `WKWebView`, whose "Other" AX role
    /// doesn't surface `AXValue`, so `SplitEditorView` exposes its fraction
    /// as a label there instead; fall back to that when `.value` is empty.
    private func scrollPercent(of element: XCUIElement) -> Int? {
        if let value = element.value as? String,
           let percent = Int(value.replacingOccurrences(of: "%", with: "")) {
            return percent
        }
        return Int(element.label.replacingOccurrences(of: "%", with: ""))
    }

    private func waitForScrollPercentChange(
        of element: XCUIElement,
        from initial: Int?,
        timeout: TimeInterval = 5
    ) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = scrollPercent(of: element)
            if current != initial {
                return current
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return scrollPercent(of: element)
    }

    func testEditorScrollSyncsPreviewWithoutPriorGesture() {
        launchOpening("assets/demo.md")

        let editor = editorContainer()
        let preview = previewContainer()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let previewBefore = scrollPercent(of: preview)

        editor.scroll(byDeltaX: 0, deltaY: -400)

        let previewAfter = waitForScrollPercentChange(of: preview, from: previewBefore)

        XCTAssertNotEqual(
            previewBefore, previewAfter,
            "Preview should sync-scroll on the very first editor scroll gesture, " +
                "with no prior manual preview scroll needed."
        )
    }

    func testPreviewScrollSyncsEditorWithoutPriorGesture() {
        launchOpening("assets/demo.md")

        let preview = previewContainer()
        let editor = editorContainer()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let editorBefore = scrollPercent(of: editor)

        preview.scroll(byDeltaX: 0, deltaY: -400)

        let editorAfter = waitForScrollPercentChange(of: editor, from: editorBefore)

        XCTAssertNotEqual(
            editorBefore, editorAfter,
            "Editor should sync-scroll on the very first preview scroll gesture."
        )
    }

    /// `assets/image-formats-test.md` is a handful of source lines carrying
    /// ten images (local + remote, several formats) — each renders far
    /// taller than its one line of Markdown, making source-line density and
    /// rendered-pixel density diverge sharply. The same shape of document
    /// that previously left one pane still scrolling while the other had
    /// already reached the end.
    ///
    /// The anchor table pins fraction 0 and 1 to each other by construction,
    /// so this is a coarse sanity check that a full scroll-to-end still lands
    /// near the end on an uneven document (WebKit rendering/scroll settling
    /// keeps this a few percent short of 100, not a precise regression guard
    /// for the interior drift this fix targets — `ScrollSyncVerifyTest`
    /// covers that precisely against the anchor-table math itself).
    func testScrollingEditorToEndTracksPreviewToEndOnUnevenDocument() {
        launchOpening("assets/image-formats-test.md")

        let editor = editorContainer()
        let preview = previewContainer()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        // typeKey sends the key command to whatever already has keyboard focus — unlike
        // scroll(byDeltaX:deltaY:), it doesn't hit-test and focus the element first — so the
        // editor's NSTextView must be made first responder explicitly. The ScrollView itself
        // reports no unoccluded space (its TextView descendant fills it entirely), so click
        // that descendant directly instead of the ScrollView wrapper.
        //
        // NSTextView's standard key bindings (see AppKit's StandardKeyBinding.dict) bind
        // moveToEndOfDocument: to Cmd+Down Arrow, not Cmd+End — plain End alone only calls
        // scrollToEndOfDocument:, which scrolls the visible frame without moving the caret or
        // firing the bounds-change notification scroll-sync depends on.
        editor.textViews.firstMatch.click()
        editor.typeKey(.downArrow, modifierFlags: .command)

        var previewPercent: Int?
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            previewPercent = scrollPercent(of: preview)
            if let percent = previewPercent, percent >= 90 {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertNotNil(previewPercent)
        XCTAssertGreaterThanOrEqual(
            previewPercent ?? 0, 90,
            "Preview should land near the end when the editor scrolls all the way down on a document " +
                "where source-line and rendered-pixel density diverge sharply."
        )
    }
}
