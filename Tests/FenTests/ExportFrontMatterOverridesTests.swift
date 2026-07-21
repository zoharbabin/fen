@testable import FenCore
import Foundation
import Testing

/// Harness gate 5 for issue #85: per-document `fen:` front-matter overrides (theme, TOC) must
/// reach `DocumentHTMLExporter`/`DocumentPDFExporter` output, degrade gracefully on malformed or
/// absent front matter (rule 3.1), and respect `Preferences.htmlDetectFrontMatter`'s
/// all-or-nothing switch (rule 3.2) -- mirroring issue #27's own rules for the live preview.
struct ExportFrontMatterOverridesTests {
    private func preferences(detectFrontMatter: Bool = true, styleName: String = "GitHub") throws -> Preferences {
        let prefs = try Preferences(
            defaults: #require(UserDefaults(suiteName: "export.frontmatter.\(UUID().uuidString)"))
        )
        prefs.htmlDetectFrontMatter = detectFrontMatter
        prefs.htmlStyleName = styleName
        return prefs
    }

    @Test @MainActor
    func htmlExportUsesTheDocumentsFrontMatterTheme() throws {
        let markdown = "---\nfen:\n  theme: Clearness\n---\n# Title"
        let prefs = try preferences(styleName: "GitHub")

        let html = DocumentHTMLExporter().export(
            markdown: markdown, documentURL: nil, preferences: prefs, mode: .selfContained
        ).html
        let withoutOverride = DocumentHTMLExporter().export(
            markdown: "# Title", documentURL: nil, preferences: prefs, mode: .selfContained
        ).html

        #expect(html != withoutOverride, "the document's own fen: theme override must change the exported CSS")
    }

    @Test @MainActor
    func pdfExportUsesTheDocumentsFrontMatterTheme() throws {
        let markdown = "---\nfen:\n  theme: Clearness\n---\n# Title"
        let prefs = try preferences(styleName: "GitHub")

        let html = DocumentPDFExporter().export(markdown: markdown, documentURL: nil, preferences: prefs)
        let withoutOverride = DocumentPDFExporter().export(
            markdown: "# Title", documentURL: nil, preferences: prefs
        )

        #expect(html != withoutOverride, "the document's own fen: theme override must change the print-composed CSS")
    }

    @Test @MainActor
    func htmlExportRendersATOCWhenFrontMatterRequestsOne() throws {
        let markdown = "---\nfen:\n  toc: true\n---\n[TOC]\n\n# Title\n\n## Section"
        let prefs = try preferences()
        prefs.htmlRendersTOC = false

        let html = DocumentHTMLExporter().export(
            markdown: markdown, documentURL: nil, preferences: prefs, mode: .selfContained
        ).html

        #expect(
            html.contains("class=\"toc-h1\""),
            "fen: toc: true must render a real TOC list even though the global preference is off"
        )
    }

    @Test @MainActor
    func malformedFrontMatterDegradesToGlobalPreferencesRatherThanThrowing() throws {
        let markdown = "---\nfen: not-a-mapping\n---\n# Title"
        let prefs = try preferences(styleName: "GitHub")

        let html = DocumentHTMLExporter().export(
            markdown: markdown, documentURL: nil, preferences: prefs, mode: .selfContained
        ).html

        #expect(html.contains("<h1>Title</h1>"), "malformed fen: front matter must not crash or corrupt the export")
    }

    @Test @MainActor
    func disablingFrontMatterDetectionIgnoresTheDocumentsThemeOverride() throws {
        let markdown = "---\nfen:\n  theme: Clearness\n---\n# Title"
        let prefs = try preferences(detectFrontMatter: false, styleName: "GitHub")

        let html = DocumentHTMLExporter().export(
            markdown: markdown, documentURL: nil, preferences: prefs, mode: .selfContained
        ).html

        // "Hiragino Sans GB" only appears in Clearness.css's font stack -- its presence would
        // mean the fen: theme override leaked through despite htmlDetectFrontMatter being off.
        #expect(
            !html.contains("Hiragino Sans GB"),
            "htmlDetectFrontMatter = false must ignore the fen: theme override, matching SplitEditorView's semantics"
        )
    }
}
