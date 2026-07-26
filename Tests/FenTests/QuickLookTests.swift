@testable import FenCore
import Foundation
import Testing

/// Proves issue #49's rules 3.1 (resiliency), 4.1/4.2 (performance), and 5.1 (single rendering
/// code path, reused from `Shared/Rendering/`, not duplicated inside the extension).
struct QuickLookTests {
    private func makeFixture(name: String, contents: Data) throws -> (fileURL: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickLookTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("\(name).md")
        try contents.write(to: fileURL)
        return (fileURL, tempRoot)
    }

    // MARK: - Rule 3.1: malformed/binary content degrades gracefully, never crashes

    @Test @MainActor
    func controlCharacterContentRendersAsLiteralTextRatherThanCrashing() throws {
        // Null and control bytes are still valid UTF-8 scalars -- confirms render() never
        // throws for well-formed-but-unusual content, only for the cases it explicitly guards
        // (size cap, genuinely undecodable data below).
        let fixture = try makeFixture(name: "control-chars", contents: Data([0x00, 0x01, 0x02, 0xE2, 0x9C, 0x93]))
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let html = try QuickLookPreviewRenderer().render(fileURL: fixture.fileURL)
        #expect(html.contains("<html"))
    }

    @Test @MainActor
    func genuinelyUndecodableDataThrowsRatherThanCrashing() throws {
        // Invalid UTF-8 byte sequence (a lone continuation byte) that String(contentsOf:) fails
        // to decode -- the controller maps this to QuickLook's own "preview unavailable"
        // fallback instead of loading anything.
        let fixture = try makeFixture(name: "undecodable", contents: Data([0xFF, 0xFE, 0x00, 0x80]))
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        #expect(throws: QuickLookPreviewRenderer.RenderError.unreadable) {
            try QuickLookPreviewRenderer().render(fileURL: fixture.fileURL)
        }
    }

    // MARK: - Rule 4.1: a size cap keeps rendering fast enough for Finder's preview panel

    @Test @MainActor
    func fileOverTheSizeCapThrowsRatherThanRendering() throws {
        let oversized = Data(repeating: 0x41, count: QuickLookPreviewRenderer.maxPreviewableFileBytes + 1)
        let fixture = try makeFixture(name: "oversized", contents: oversized)
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        #expect(throws: QuickLookPreviewRenderer.RenderError.fileTooLarge(byteCount: oversized.count)) {
            try QuickLookPreviewRenderer().render(fileURL: fixture.fileURL)
        }
    }

    @Test @MainActor
    func renderingAOneMegabyteFileStaysUnderABoundedTime() throws {
        let large = String(repeating: "Lorem ipsum dolor sit amet.\n", count: 40000)
        let fixture = try makeFixture(name: "large", contents: Data(large.utf8))
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let before = ContinuousClock.now
        _ = try QuickLookPreviewRenderer().render(fileURL: fixture.fileURL)
        let elapsed = before.duration(to: .now)
        #expect(elapsed < .seconds(5), "a 1MB document must render well within a Quick Look popup's patience")
    }

    // MARK: - Rule 4.2: heavy imports (Mermaid/MathJax) load lazily, only when referenced

    @Test @MainActor
    func mermaidScriptIsAbsentWhenPreferenceIsOff() throws {
        let fixture = try makeFixture(name: "plain", contents: Data("# No diagrams here".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "quicklook.perf.\(UUID().uuidString)"))
        )
        preferences.htmlMermaid = false
        preferences.htmlMathJax = false

        let html = try QuickLookPreviewRenderer().render(fileURL: fixture.fileURL, preferences: preferences)
        #expect(!html.contains("mermaid"))
        #expect(!html.contains("MathJax"))
    }

    // MARK: - Rule 5.1: one rendering code path, reused from Shared/Rendering/

    @Test func rendererDelegatesToDocumentHTMLExporterRatherThanReimplementingComposition() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QuickLookTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Shared/QuickLook/QuickLookPreviewRenderer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("DocumentHTMLExporter()"))
        #expect(!source.contains("MarkdownRenderer()"), "must reuse DocumentHTMLExporter, not reimplement its steps")
        #expect(!source.contains("HTMLComposer()"), "must reuse DocumentHTMLExporter, not reimplement its steps")
    }
}
