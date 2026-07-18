import AppKit
import XCTest

/// E2E proof for issue #18, harness gate 6 (manual/UI verification pass): pastes a real PNG onto
/// the clipboard and drives an actual Cmd+V into the real app's editor, then asserts on the real
/// text view's content and the real sidecar file written to disk -- not on `ImageSidecarWriter`/
/// `MarkdownFormatting` called directly (that's `ImagePasteInsertionTests`/`ImagePasteE2ETest` in
/// `Tests/FenTests`).
@MainActor
final class ImagePasteUITests: XCTestCase {
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

    /// Same launch strategy as `FormattingToolbarUITests.launch` -- opens a real file from this
    /// test bundle's sibling app build, in a freshly launched process.
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

    /// A minimal but real, valid single-pixel PNG -- not placeholder bytes -- so the pasteboard
    /// offers the same `.png` type a real screenshot/copy would.
    private var onePixelPNG: Data {
        Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
    }

    private func attachScreenshot(named name: String) {
        let screenshot = documentWindow.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Rule 5.3 (issue #18): pasting a real image via Cmd+V into a saved document's real editor
    /// writes the sidecar file next to the document and inserts a Markdown image link -- driven
    /// through the actual pasteboard and the actual key command, not a direct call into
    /// `readSelection(from:type:)`.
    func testPastingRealPNGIntoSavedDocumentWritesSidecarFileAndInsertsLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagePasteUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // A literal "notes.md" collides with a same-named window macOS's own session restoration
        // can leave open from an earlier test run in this same app; a UUID-qualified name -- the
        // same approach every other UI test in this suite already uses -- makes the window title
        // this test looks up for unique to this run, and the sidecar folder name (which tracks
        // the document's own basename) unique right along with it.
        let documentName = "notes-\(UUID().uuidString)"
        let documentURL = directory.appendingPathComponent("\(documentName).md")
        try "".write(to: documentURL, atomically: true, encoding: .utf8)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(onePixelPNG, forType: .png)

        launch(fileURL: documentURL)

        let editor = documentWindow.scrollViews["EditorTextView"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("v", modifierFlags: .command)

        let sidecarFile = directory.appendingPathComponent("\(documentName).assets/image-1.png")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !FileManager.default.fileExists(atPath: sidecarFile.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        attachScreenshot(named: "image-paste-inserted-link")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarFile.path),
            "Expected pasting the image to write \(sidecarFile.path)"
        )
        XCTAssertEqual(try Data(contentsOf: sidecarFile), onePixelPNG)

        let value = editor.value as? String
        XCTAssertEqual(value, "![image-1.png](\(documentName).assets/image-1.png)")
    }
}
