import Foundation

/// Per-document preview overrides parsed from a Markdown document's own `fen:` front-matter
/// key (issue #27), e.g. `fen: { theme: GitHub2 Dark, toc: true }`. A plain, stateless value
/// type computed fresh from each render's parsed front matter -- never persisted, never shared
/// across documents, and never written back to `Preferences` (rule 1.1).
public struct DocumentPreviewOverrides: Sendable, Equatable {
    /// The bundled CSS style name to use instead of `Preferences.htmlStyleName`, or `nil` to
    /// fall back to the global preference. Only ever set to a name `HTMLComposer
    /// .availablePreviewStyles()` actually lists (rule 2.1) -- a typo'd or nonexistent theme
    /// name in the document's front matter is ignored, not passed through unchecked.
    public let styleName: String?

    /// Whether to render `[TOC]` markers, overriding `Preferences.htmlRendersTOC`, or `nil` to
    /// fall back to the global preference.
    public let rendersTOC: Bool?

    public static let none = DocumentPreviewOverrides(styleName: nil, rendersTOC: nil)

    public init(styleName: String?, rendersTOC: Bool?) {
        self.styleName = styleName
        self.rendersTOC = rendersTOC
    }

    /// Parses the `fen:` key out of a document's already-extracted front matter (e.g.
    /// `MarkdownRenderer.RenderResult.frontMatter`, or `MarkdownRenderer.peekFrontMatter(_:)`).
    /// Never throws: any front matter that doesn't have a `fen:` key, or where `fen:` isn't a
    /// dictionary, or whose values are the wrong type, degrades to `.none` field-by-field
    /// rather than failing the whole parse (rule 3.1).
    public static func parse(frontMatter: [String: Any]?) -> DocumentPreviewOverrides {
        guard let fen = frontMatter?["fen"] as? [String: Any] else { return .none }

        let requestedStyleName = fen["theme"] as? String
        let styleName = requestedStyleName.flatMap { name in
            HTMLComposer.availablePreviewStyles().contains(name) ? name : nil
        }
        let rendersTOC = fen["toc"] as? Bool

        return DocumentPreviewOverrides(styleName: styleName, rendersTOC: rendersTOC)
    }
}
