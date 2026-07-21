@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #27, rule 1.1: `DocumentPreviewOverrides` is a plain, stateless
/// value type with no shared mutable state, so two documents' front matter -- parsed and
/// composed in the same process -- never leak into each other's resolved style/TOC state.
struct DocumentPreviewOverridesIsolationTests {
    @Test
    func twoDocumentsNeverShareResolvedOverrides() {
        let overridesA = DocumentPreviewOverrides.parse(frontMatter: ["fen": ["theme": "GitHub2 Dark", "toc": true]])
        let overridesB = DocumentPreviewOverrides.parse(frontMatter: ["fen": ["theme": "Clearness", "toc": false]])

        #expect(overridesA.styleName == "GitHub2 Dark")
        #expect(overridesA.rendersTOC == true)
        #expect(overridesB.styleName == "Clearness")
        #expect(
            overridesB.rendersTOC == false,
            "parsing document B's front matter must never affect document A's already-resolved overrides"
        )
    }

    @Test @MainActor
    func twoComposedDocumentsReflectOnlyTheirOwnOverride() {
        let renderer = MarkdownRenderer()
        let renderedA = renderer.render("# A")
        let renderedB = renderer.render("# B")

        let prefs = Preferences()
        prefs.htmlStyleName = "GitHub"

        let composer = HTMLComposer()
        let htmlA = composer.compose(
            title: nil,
            body: renderedA.html,
            preferences: prefs,
            documentOverrides: DocumentPreviewOverrides(styleName: "GitHub2 Dark", rendersTOC: nil)
        )
        let htmlB = composer.compose(
            title: nil,
            body: renderedB.html,
            preferences: prefs,
            documentOverrides: DocumentPreviewOverrides(styleName: "Clearness", rendersTOC: nil)
        )

        #expect(htmlA != htmlB, "each document's compose call must reflect only its own override")
    }

    /// Issue #85, rule 1.1: two `DocumentHTMLExporter.export` calls -- a stateless value type
    /// (rule 1.1) -- exporting different documents with different `fen:` front matter never
    /// leak one document's resolved override into the other's exported output.
    @Test @MainActor
    func twoExportsNeverShareResolvedOverrides() throws {
        let markdownA = "---\nfen:\n  theme: GitHub2 Dark\n---\n# A"
        let markdownB = "---\nfen:\n  theme: Clearness\n---\n# B"
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: "docoverrides.iso.\(UUID())")))
        prefs.htmlStyleName = "GitHub"

        let exporter = DocumentHTMLExporter()
        let htmlA = exporter.export(markdown: markdownA, documentURL: nil, preferences: prefs, mode: .selfContained)
            .html
        let htmlB = exporter.export(markdown: markdownB, documentURL: nil, preferences: prefs, mode: .selfContained)
            .html

        #expect(htmlA != htmlB, "each export must reflect only its own document's front-matter override")
    }
}
