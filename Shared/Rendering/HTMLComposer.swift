import Foundation

/// Composes a full HTML document by wrapping rendered markdown HTML
/// with CSS styles, JavaScript extensions, and a document template.
public struct HTMLComposer: Sendable {
    public init() {}

    /// Compose a complete HTML document from rendered markdown body.
    ///
    /// `sourceLineCount` and `sourceLineOffset` feed `scroll-sync.js`'s anchor table, which maps
    /// scroll fractions between the source Markdown and the rendered preview to correct for
    /// uneven content density (e.g. a code block or image versus plain text). `sourceLineOffset`
    /// is the number of lines stripped as front matter before rendering (0 if none) — cmark-gfm's
    /// `data-sourcepos` is relative to the stripped text, but scroll fractions need to be relative
    /// to the raw source the editor displays, so `scroll-sync.js` adds this back before dividing.
    public func compose(
        title: String?,
        body: String,
        preferences: Preferences,
        sourceLineCount: Int = 0,
        sourceLineOffset: Int = 0
    ) -> String {
        var styleTags: [String] = []
        var scriptTags: [String] = []

        if let css = loadStyleCSS(named: preferences.htmlStyleName) {
            styleTags.append(inlineStyle(css))
        }

        styleTags.append(inlineStyle(fontScaleCSS(preferences: preferences)))
        styleTags.append(inlineStyle(Self.listMarkerCSS))
        styleTags.append(inlineStyle(Self.alertsCSS))

        let highlighting = syntaxHighlightingTags(preferences: preferences)
        styleTags += highlighting.styles
        scriptTags += highlighting.scripts

        scriptTags += mathJaxTags(preferences: preferences)

        let mermaid = mermaidTags(preferences: preferences)
        styleTags += mermaid.styles
        scriptTags += mermaid.scripts

        scriptTags += taskListTags(preferences: preferences)
        scriptTags.append(inlineScript(Self.listMarkerStartJS))
        scriptTags += scrollSyncTags(sourceLineCount: sourceLineCount, sourceLineOffset: sourceLineOffset)

        return htmlDocument(
            title: title,
            body: body,
            styleTags: styleTags,
            scriptTags: scriptTags,
            includeViewportMeta: true
        )
    }

    /// Scales all text-bearing content by the ratio of the user's font size to the default,
    /// using WebKit's `zoom` (this preview only ever runs inside `WKWebView`) rather than
    /// rewriting every theme's hardcoded px values. `zoom` cascades to descendants, so images
    /// and Mermaid's rendered SVGs get an inverse `zoom` to cancel it out and stay at their
    /// natural size, per the requirement that only text should scale.
    ///
    /// The ratios live in CSS custom properties rather than literal `zoom:` values so
    /// `PreviewWebView` can change them later with a plain `style.setProperty` call -- no
    /// recompose, no reload. `ScrollSyncJS.swift`'s `fontScaleAssignmentJS` sets an inline
    /// style on `documentElement`, which overrides this `:root` rule's value without
    /// touching the page's HTML or navigating, so a zoom step never resets scroll to 0.
    private func fontScaleCSS(preferences: Preferences) -> String {
        let (scale, inverseScale) = Self.fontScaleRatios(fontSize: preferences.fontSize)
        return """
        :root { --fen-font-scale: \(scale); --fen-font-inverse-scale: \(inverseScale); }
        body { zoom: var(--fen-font-scale); }
        img, svg { zoom: var(--fen-font-inverse-scale); }
        """
    }

    /// The single source of truth for the text/inverse-image scale ratios, shared between the
    /// value baked into composed HTML and the value `PreviewWebView` writes live on a zoom step,
    /// so the two can never drift apart.
    static func fontScaleRatios(fontSize: CGFloat) -> (scale: CGFloat, inverseScale: CGFloat) {
        (fontSize / Preferences.defaultFontSize, Preferences.defaultFontSize / fontSize)
    }

    /// Replaces every theme's native `list-style: outside` markers with a CSS-counter/bullet
    /// `::before` plus a hanging indent (`padding-left` + negative `text-indent`). WebKit's
    /// `zoom` (used by `fontScaleCSS` above) breaks the layout link between a native outside
    /// marker and its list item's wrapped lines, so wrapped lines drift right of the first
    /// line at any non-1 zoom factor. A hanging indent never depends on that marker/line-box
    /// relationship, so it stays aligned regardless of zoom. Applied once here rather than
    /// duplicated across all seven theme files.
    private static let listMarkerCSS = """
    ol, ul { list-style: none; padding-left: 0; margin-left: 0; }
    ol { counter-reset: fen-ol; }
    ol > li { counter-increment: fen-ol; padding-left: 1.8em; text-indent: -1.8em; }
    ol > li::before { content: counter(fen-ol) '. '; display: inline-block; width: 1.8em; text-indent: 0; }
    ul > li { padding-left: 1.8em; text-indent: -1.8em; }
    ul > li::before { content: '•'; display: inline-block; width: 1.8em; text-indent: 0; }
    li:has(> input[type="checkbox"]) { padding-left: 1.5em; text-indent: 0; }
    li:has(> input[type="checkbox"])::before { content: none; }
    """

    /// WebKit in this app doesn't resolve `attr(start type(<integer>))` inside `calc()`
    /// (confirmed via `CSS.supports`), so a Markdown ordered list's custom start number
    /// (`<ol start="5">`, from e.g. `5. five`) can't be picked up in pure CSS. Read it from
    /// the DOM instead and set the counter's starting value as an inline style, which wins
    /// over the stylesheet rule above by specificity.
    private static let listMarkerStartJS = """
    document.querySelectorAll('ol[start]').forEach(function (ol) {
        var start = parseInt(ol.getAttribute('start'), 10);
        if (!isNaN(start)) { ol.style.counterReset = 'fen-ol ' + (start - 1); }
    });
    """

    /// Visual treatment for the 5 GFM alert types (issue #29's `MarkdownRenderer.applyAlertMarkup`
    /// emits `markdown-alert markdown-alert-<type>` on the blockquote). Applied once here rather
    /// than duplicated across all 7 theme files, the same reasoning `listMarkerCSS` above already
    /// uses. A `.markdown-alert` class selector out-specifies a theme's plain `blockquote` rule,
    /// so this always wins the border-color/background cascade regardless of style-tag order.
    /// Colors are semi-transparent so they read correctly over both light and dark theme
    /// backgrounds without needing a per-theme variant.
    private static let alertsCSS = """
    blockquote.markdown-alert { border-left-width: 4px; border-radius: 3px; }
    blockquote.markdown-alert-note { border-left-color: #0969da; background-color: rgba(9, 105, 218, 0.1); }
    blockquote.markdown-alert-tip { border-left-color: #1a7f37; background-color: rgba(26, 127, 55, 0.1); }
    blockquote.markdown-alert-important {
        border-left-color: #8250df; background-color: rgba(130, 80, 223, 0.1);
    }
    blockquote.markdown-alert-warning { border-left-color: #9a6700; background-color: rgba(154, 103, 0, 0.1); }
    blockquote.markdown-alert-caution { border-left-color: #cf222e; background-color: rgba(207, 34, 46, 0.1); }
    p.markdown-alert-title { font-weight: bold; margin-top: 0; }
    .markdown-alert-note p.markdown-alert-title { color: #0969da; }
    .markdown-alert-tip p.markdown-alert-title { color: #1a7f37; }
    .markdown-alert-important p.markdown-alert-title { color: #8250df; }
    .markdown-alert-warning p.markdown-alert-title { color: #9a6700; }
    .markdown-alert-caution p.markdown-alert-title { color: #cf222e; }
    """

    private func syntaxHighlightingTags(preferences: Preferences) -> (styles: [String], scripts: [String]) {
        guard preferences.htmlSyntaxHighlighting else { return ([], []) }

        var styles: [String] = []
        var scripts: [String] = []
        if let themeCSS = loadHighlightThemeCSS(named: preferences.htmlHighlightingThemeName) {
            styles.append(inlineStyle(themeCSS))
        }
        if preferences.htmlLineNumbers, let lineNumCSS = loadHighlightLineNumbersCSS() {
            styles.append(inlineStyle(lineNumCSS))
        }
        if let highlightJS = loadHighlightCoreJS() {
            scripts.append(inlineScript(highlightJS))
        }
        if preferences.htmlLineNumbers {
            scripts.append(inlineScript("window.__fenLineNumbers = true;"))
        }
        if let initJS = loadHighlightInitJS() {
            scripts.append(inlineScript(initJS))
        }
        return (styles, scripts)
    }

    private func mathJaxTags(preferences: Preferences) -> [String] {
        guard preferences.htmlMathJax else { return [] }

        var scripts: [String] = []
        if preferences.htmlMathJaxInlineDollar {
            // MathJax v3's config object must exist before its script tag loads.
            scripts.append(inlineScript("""
            window.MathJax = {
                tex: { inlineMath: [['$', '$'], ['\\\\(', '\\\\)']] }
            };
            """))
        }
        if let mathJaxJS = loadExtensionFile(named: "mathjax-tex-svg", ext: "js") {
            scripts.append(inlineScript(mathJaxJS))
        }
        return scripts
    }

    private func mermaidTags(preferences: Preferences) -> (styles: [String], scripts: [String]) {
        guard preferences.htmlMermaid else { return ([], []) }

        let mermaidTheme = preferences.htmlStyleName.contains("Dark") ? "dark" : "default"
        let themeScript = inlineScript("window.__fenMermaidTheme = \"\(mermaidTheme)\";")

        let styles = [loadExtensionFile(named: "mermaid-zoom", ext: "css")]
            .compactMap(\.self)
            .map { inlineStyle($0) }

        let scripts = [themeScript] + [
            loadExtensionFile(named: "mermaid.min", ext: "js"),
            loadExtensionFile(named: "mermaid-zoom", ext: "js"),
            loadExtensionFile(named: "mermaid.init", ext: "js"),
        ]
        .compactMap(\.self)
        .map { inlineScript($0) }

        return (styles, scripts)
    }

    private func taskListTags(preferences: Preferences) -> [String] {
        guard preferences.htmlTaskList,
              let taskJS = loadExtensionFile(named: "tasklist", ext: "js") else { return [] }
        return [inlineScript(taskJS)]
    }

    private func scrollSyncTags(sourceLineCount: Int, sourceLineOffset: Int) -> [String] {
        guard let scrollSyncJS = loadResourceFile(name: "scroll-sync", ext: "js", subdirectory: "ScrollSync")
        else { return [] }
        return [
            inlineScript(
                "window.__fenTotalSourceLines = \(sourceLineCount); " +
                    "window.__fenSourceLineOffset = \(sourceLineOffset);"
            ),
            inlineScript(scrollSyncJS),
        ]
    }

    private func htmlDocument(
        title: String?,
        body: String,
        styleTags: [String],
        scriptTags: [String],
        includeViewportMeta: Bool
    ) -> String {
        let titleTag = title.map { "<title>\($0)</title>" } ?? ""
        let styleBlock = styleTags.joined(separator: "\n")
        let scriptBlock = scriptTags.joined(separator: "\n")
        let viewportMeta = includeViewportMeta
            ? "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, user-scalable=yes\">"
            : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        \(viewportMeta)
        \(titleTag)
        \(styleBlock)
        </head>
        <body>
        \(body)
        \(scriptBlock)
        </body>
        </html>
        """
    }

    /// Compose HTML suitable for export (optionally without styles/scripts).
    public func composeForExport(
        title: String?,
        body: String,
        preferences: Preferences,
        includeStyles: Bool,
        includeHighlighting: Bool
    ) -> String {
        var styleTags: [String] = []
        var scriptTags: [String] = []

        if includeStyles, let css = loadStyleCSS(named: preferences.htmlStyleName) {
            styleTags.append(inlineStyle(css))
        }

        if includeHighlighting, preferences.htmlSyntaxHighlighting {
            if let themeCSS = loadHighlightThemeCSS(named: preferences.htmlHighlightingThemeName) {
                styleTags.append(inlineStyle(themeCSS))
            }
            if let highlightJS = loadHighlightCoreJS() {
                scriptTags.append(inlineScript(highlightJS))
            }
            if let initJS = loadHighlightInitJS() {
                scriptTags.append(inlineScript(initJS))
            }
        }

        return htmlDocument(
            title: title,
            body: body,
            styleTags: styleTags,
            scriptTags: scriptTags,
            includeViewportMeta: false
        )
    }

    // MARK: - Resource Loading

    private func loadStyleCSS(named name: String) -> String? {
        loadResourceFile(name: name, ext: "css", subdirectory: "Styles")
    }

    private func loadHighlightThemeCSS(named name: String) -> String? {
        loadResourceFile(name: name, ext: "css", subdirectory: "Highlight/themes")
    }

    private func loadHighlightCoreJS() -> String? {
        loadResourceFile(name: "highlight.min", ext: "js", subdirectory: "Highlight")
    }

    private func loadHighlightInitJS() -> String? {
        loadResourceFile(name: "highlight.init", ext: "js", subdirectory: "Highlight")
    }

    private func loadHighlightLineNumbersCSS() -> String? {
        loadResourceFile(name: "line-numbers", ext: "css", subdirectory: "Highlight")
    }

    private func loadExtensionFile(named name: String, ext: String) -> String? {
        loadResourceFile(name: name, ext: ext, subdirectory: "Extensions")
    }

    private func loadResourceFile(name: String, ext: String, subdirectory: String) -> String? {
        guard let url = coreBundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - HTML Helpers

    private func inlineStyle(_ css: String) -> String {
        "<style>\n\(css)\n</style>"
    }

    private func inlineScript(_ js: String) -> String {
        "<script>\n\(js)\n</script>"
    }

    // MARK: - Available Styles

    public static func availablePreviewStyles() -> [String] {
        guard let url = coreBundle.url(forResource: "Styles", withExtension: nil),
              let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return [] }
        return contents
            .filter { $0.pathExtension == "css" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public static func availableHighlightingThemes() -> [String] {
        guard let url = coreBundle.url(forResource: "themes", withExtension: nil, subdirectory: "Highlight"),
              let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return [] }
        return contents
            .filter { $0.pathExtension == "css" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
