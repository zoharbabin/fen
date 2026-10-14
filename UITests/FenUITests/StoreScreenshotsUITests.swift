import AppKit
import XCTest

/// Takes the raw Mac screenshots for the App Store listing (issue #40). It skips unless
/// `TEST_RUNNER_FEN_STORE_SHOTS_DIR` names a folder. Run it through `scripts/make-store-screenshots.sh`,
/// which also turns the captures into the sizes Apple wants.
///
/// The app runs with a throwaway home (`CFFIXED_USER_HOME`) and the sample workspace in
/// `assets/store/sample-workspace`, so nothing of yours appears in the pictures.
@MainActor
final class StoreScreenshotsUITests: XCTestCase {
    private static let bundleIdentifier = "com.zoharbabin.fen"
    private var app: XCUIApplication!
    private var root: URL!
    private var output: URL!

    override func setUp() async throws {
        let dir = try XCTUnwrap(
            ProcessInfo.processInfo.environment["FEN_STORE_SHOTS_DIR"],
            "Set TEST_RUNNER_FEN_STORE_SHOTS_DIR."
        )
        continueAfterFailure = false
        output = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fen-store-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("home/.fen"),
            withIntermediateDirectories: true
        )
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            repo.deleteLastPathComponent()
        }
        try FileManager.default.copyItem(
            at: repo.appendingPathComponent("assets/store/sample-workspace"),
            to: root.appendingPathComponent("Trailhead")
        )
        try Self.seedRegistry(in: root)
    }

    override func tearDown() async throws {
        app?.terminate()
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Registers the sample folder as a workspace, so no open panel is needed.
    private nonisolated static func seedRegistry(in root: URL) throws {
        let settings: [String: Any] = [
            "agentBranches": "perAgent", "aiDataAccess": "localProvidersOnly", "approvalMode": "ask",
            "clonedByFen": false, "enrichOnSave": false, "enrichSchedule": "off", "excludeGlobs": [],
            "includeGlobs": ["**/*.md", "**/*.markdown", "**/*.mdx", "**/*.txt"], "maxFileBytes": 2_000_000,
            "mcpAccess": "disabled", "pushesAIChanges": false,
            "writePolicy": [
                "autoApproveConfirmed": false, "autoApproveMinConfidence": 0.8, "autoApproveReplacing": [],
                "maxChangedFraction": 0.5, "maxFilesPerRun": 20, "overrides": [],
            ] as [String: Any],
        ]
        let workspace: [String: Any] = [
            "id": UUID().uuidString, "name": "Trailhead", "addedAt": "2026-10-01T09:00:00Z",
            "path": root.appendingPathComponent("Trailhead").path, "settings": settings,
        ]
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "workspaces": [workspace]])
        try data.write(to: root.appendingPathComponent("home/.fen/workspaces.json"))
        // A local Ollama model for the Ask pictures. It holds no secret.
        let provider: [String: Any] = [
            "id": UUID().uuidString, "kind": "ollama", "name": "Ollama",
            "baseURL": "http://localhost:11434", "model": "gemma4:latest",
        ]
        let providers: [String: Any] = ["version": 1, "providers": [provider], "selectedID": provider["id"] as Any]
        try JSONSerialization.data(withJSONObject: providers)
            .write(to: root.appendingPathComponent("home/.fen/ai-providers.json"))
    }

    private func launch(opening name: String) {
        var productsDirectory = Bundle(for: Self.self).bundleURL
        for _ in 0 ..< 4 {
            productsDirectory.deleteLastPathComponent()
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .forEach { $0.forceTerminate() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [
            "-ApplePersistenceIgnoreState", "YES", "-htmlMermaid", "YES", "-htmlMathJax", "YES",
            "-htmlMathJaxInlineDollar",
            "YES",
            "-editorAppearanceMode", "dark", "-previewAppearanceMode", "dark",
        ]
        configuration.environment = ["CFFIXED_USER_HOME": root.appendingPathComponent("home").path]
        let opened = expectation(description: "open")
        NSWorkspace.shared.open(
            [root.appendingPathComponent("Trailhead/\(name)")],
            withApplicationAt: productsDirectory.appendingPathComponent("Fen.app"),
            configuration: configuration
        ) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func save(_ element: XCUIElement, as name: String) throws {
        let png = element.screenshot().pngRepresentation
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    func testSplit() throws {
        launch(opening: "Launch plan.md")
        let window = app.windows.firstMatch
        let chart = window.webViews.firstMatch.staticTexts["Beta feedback"]
        XCTAssertTrue(chart.waitForExistence(timeout: 30), "the chart never drew:\n\(window.debugDescription)")
        try save(window, as: "mac-split")
    }

    func testMathInPreview() throws {
        launch(opening: "Pricing.md")
        let window = app.windows.firstMatch
        window.radioButtons["Preview"].firstMatch.click()
        let heading = window.webViews.firstMatch.staticTexts["Break-even"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30), window.debugDescription)
        // MathJax typesets after the page loads.
        let typeset = window.webViews.firstMatch.descendants(matching: .any).matching(identifier: "LTV").firstMatch
        _ = typeset.waitForExistence(timeout: 10)
        try save(window, as: "mac-preview")
    }

    func testWorkspaces() throws {
        launch(opening: "Launch plan.md")
        app.typeKey("l", modifierFlags: [.command, .shift])
        let predicate = NSPredicate(format: "title == 'Workspaces' OR identifier == 'workspaces'")
        let window = app.windows.matching(predicate).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), app.debugDescription)
        let row = window.staticTexts["Trailhead"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), window.debugDescription)
        row.click()
        XCTAssertTrue(
            window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Launch plan'")).firstMatch
                .waitForExistence(timeout: 30),
            window.debugDescription
        )
        try save(window, as: "mac-workspace")
        let field = window.toolbars.searchFields.firstMatch
        field.click()
        field.typeText("subscription price")
        let result = window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Launch plan'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), window.debugDescription)
        try save(window, as: "mac-search")
    }

    func testAsk() throws {
        launch(opening: "Launch plan.md")
        app.typeKey("l", modifierFlags: [.command, .shift])
        let predicate = NSPredicate(format: "title == 'Workspaces' OR identifier == 'workspaces'")
        let window = app.windows.matching(predicate).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), app.debugDescription)
        window.staticTexts["Trailhead"].firstMatch.click()
        // Wait for the local model to read every note, so the answer can use meaning, not only words.
        let ready = window.staticTexts.matching(NSPredicate(format: "value CONTAINS 'searchable'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 60), window.debugDescription)
        window.checkBoxes["Ask"].firstMatch.click()
        let field = window.textFields["What did we decide about…?"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), window.debugDescription)
        field.click()
        field.typeText("Why did we choose a yearly price?\n")
        let sources = window.staticTexts["Sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 240), window.debugDescription)
        field.typeKey(.rightArrow, modifierFlags: [])
        try save(window, as: "mac-ask")
    }

    func testRelated() throws {
        launch(opening: "Roadmap.md")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.webViews.firstMatch.waitForExistence(timeout: 20))
        // Select the "Do we drop the social feed?" line.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.517)).click()
        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: [.command, .shift])
        let card = window.descendants(matching: .any).matching(identifier: "RelatedSuggestions").firstMatch
        let found = card.waitForExistence(timeout: 60)
        try save(window, as: found ? "mac-related" : "debug-related")
        XCTAssertTrue(found, window.debugDescription)
    }
}
