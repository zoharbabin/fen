import Foundation

public extension Notification.Name {
    /// Posted by macOS's "Export to HTML…" menu command (`macOS/ExportHTMLCommands.swift`) to
    /// ask the focused `SplitEditorView` to present its export panel -- the same
    /// `NotificationCenter` pattern `DocumentOutline.toggleOutlineNotification` already uses,
    /// since `SplitEditorView` (in `FenCore`) is the observer, not the macOS app target.
    static let exportToHTML = Notification.Name("exportToHTML")
}

/// Renders a document's Markdown and composes it into exportable HTML, then resolves its image
/// references per `mode` -- the one entry point both macOS's `NSSavePanel` flow and iOS's
/// `.fileExporter` flow call, so the two platforms never duplicate this logic (issue #31, rule
/// 5.1). Holds no stored state: every call is a pure function of its arguments.
public struct DocumentHTMLExporter: Sendable {
    public struct Result: Sendable {
        public let html: String
        /// Assets to copy/embed alongside `html` -- always empty for `.selfContained`, since
        /// that mode inlines every resolvable image directly into `html` as a `data:` URI.
        public let assets: [ExportResolvedAsset]
    }

    public init() {}

    /// `documentURL` is the source document's on-disk location, used to resolve relative image
    /// references -- `nil` for an unsaved document, in which case image references are left
    /// exactly as rendered (there is no directory to resolve them against). `mode`'s
    /// `linkedAssets` case carries the destination file's base name, used to name the `.assets`
    /// folder its resolved assets belong in.
    public func export(
        markdown: String,
        documentURL: URL?,
        preferences: Preferences,
        mode: ExportAssetMode
    ) -> Result {
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

        let composed = HTMLComposer().composeForExport(
            title: rendered.title,
            body: rendered.html,
            preferences: preferences,
            includeStyles: true,
            includeHighlighting: true,
            documentOverrides: documentOverrides
        )

        guard let documentDirectory = documentURL?.deletingLastPathComponent() else {
            return Result(html: composed, assets: [])
        }

        let resolved = ExportAssetResolver().resolve(html: composed, documentDirectory: documentDirectory, mode: mode)
        return Result(html: resolved.html, assets: resolved.assets)
    }
}
