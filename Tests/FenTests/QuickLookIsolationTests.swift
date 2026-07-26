@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #49, rule 1.1: two `QuickLookPreviewRenderer` calls simulating two
/// rapid Quick Look invocations (each request gets a fresh `PreviewViewController` instance in
/// the real extension) never share or leak state -- `render` is a pure function of its arguments
/// and the filesystem at call time, mirrors `ExportHTMLIsolationTests.swift`'s two-instance
/// pattern.
struct QuickLookIsolationTests {
    private func makeFixture(name: String, markdown: String) throws -> (fileURL: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickLookIsolationTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("\(name).md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return (fileURL, tempRoot)
    }

    @Test @MainActor
    func twoRendersOfDifferentDocumentsConcurrentlyNeverCrossContaminate() async throws {
        let fixtureA = try makeFixture(name: "alpha", markdown: "# Alpha document")
        let fixtureB = try makeFixture(name: "beta", markdown: "# Beta document")
        defer {
            try? FileManager.default.removeItem(at: fixtureA.tempRoot)
            try? FileManager.default.removeItem(at: fixtureB.tempRoot)
        }

        async let htmlA = try QuickLookPreviewRenderer().render(fileURL: fixtureA.fileURL)
        async let htmlB = try QuickLookPreviewRenderer().render(fileURL: fixtureB.fileURL)
        let (outputA, outputB) = try await (htmlA, htmlB)

        #expect(outputA.contains("Alpha document"))
        #expect(outputB.contains("Beta document"))
        // Checks for the specific heading text, not a bare "Beta"/"Alpha" substring -- the
        // vendored highlight.min.js this composes in by default contains "Beta" as a language
        // keyword, unrelated to any cross-document leak (mirrors CLIRunnerIsolationTests.swift).
        #expect(!outputA.contains("Beta document"), "render A's output must never reference document B's content")
        #expect(!outputB.contains("Alpha document"), "render B's output must never reference document A's content")
    }

    @Test @MainActor
    func eachRenderConstructsItsOwnPreferencesRatherThanSharingState() throws {
        let fixture = try makeFixture(name: "prefs", markdown: "plain text, no math or diagrams")
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let prefsA = try Preferences(defaults: #require(UserDefaults(suiteName: "quicklook.iso.\(UUID().uuidString)")))
        let prefsB = try Preferences(defaults: #require(UserDefaults(suiteName: "quicklook.iso.\(UUID().uuidString)")))
        prefsA.htmlMermaid = true
        prefsB.htmlMermaid = false

        let htmlA = try QuickLookPreviewRenderer().render(fileURL: fixture.fileURL, preferences: prefsA)
        let htmlB = try QuickLookPreviewRenderer().render(fileURL: fixture.fileURL, preferences: prefsB)

        #expect(htmlA.contains("mermaid"))
        #expect(!htmlB.contains("mermaid"), "renderer B's own Preferences instance must not see renderer A's toggle")
    }
}
