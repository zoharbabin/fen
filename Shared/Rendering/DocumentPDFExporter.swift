import Foundation

public extension Notification.Name {
    /// Posted by macOS's "Export to PDF…" menu command (`macOS/ExportPDFCommands.swift`) to ask
    /// the focused `SplitEditorView` to present its export panel -- mirrors `.exportToHTML`
    /// (issue #31).
    static let exportToPDF = Notification.Name("exportToPDF")
}

/// Renders a document's Markdown and composes it into paginated-print-ready HTML, then inlines
/// its image references, for `PDFRenderer` to turn into a PDF -- the one entry point both
/// macOS's `NSSavePanel` flow and iOS's `.fileExporter` flow call (issue #30, mirrors
/// `DocumentHTMLExporter`, rule 5.1). Holds no stored state: every call is a pure function of
/// its arguments (rule 1.1).
public struct DocumentPDFExporter: Sendable {
    public init() {}

    /// `documentURL` is the source document's on-disk location, used to resolve relative image
    /// references -- `nil` for an unsaved document, in which case image references are left
    /// exactly as rendered. Images are always inlined as `data:` URIs (`ExportAssetResolver`'s
    /// `.selfContained` mode, issue #31 rules 4.1/4.2) since a PDF is one opaque file with no
    /// "linked assets" equivalent.
    public func export(markdown: String, documentURL: URL?, preferences: Preferences) -> String {
        let renderer = MarkdownRenderer()
        // Per-document overrides (issue #85, mirrors SplitEditorView.renderMarkdown's issue #27
        // pattern) only apply when front-matter detection itself is on -- otherwise the
        // `---...---` block renders as literal content, and a `fen:` key inside it must not
        // silently still drive export output (rule 3.2).
        let documentOverrides: DocumentPreviewOverrides = preferences.htmlDetectFrontMatter
            ? .parse(frontMatter: renderer.peekFrontMatter(markdown))
            : .none

        var options = MarkdownRenderer.Options.from(preferences: preferences)
        options.sourcePositions = false
        options.renderTOC = documentOverrides.rendersTOC ?? options.renderTOC
        let rendered = renderer.render(markdown, options: options)

        let composed = HTMLComposer().composeForPrint(
            title: rendered.title,
            body: rendered.html,
            preferences: preferences,
            documentOverrides: documentOverrides
        )

        guard let documentDirectory = documentURL?.deletingLastPathComponent() else {
            return composed
        }

        return ExportAssetResolver().resolve(
            html: composed, documentDirectory: documentDirectory, mode: .selfContained
        ).html
    }
}
