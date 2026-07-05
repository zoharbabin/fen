import Foundation

/// Composes a full HTML document by wrapping rendered markdown HTML
/// with CSS styles, JavaScript extensions, and a document template.
public struct HTMLComposer: Sendable {
    public init() {}

    /// Compose a complete HTML document from rendered markdown body.
    public func compose(
        title: String?,
        body: String,
        preferences: Preferences
    ) -> String {
        var styleTags: [String] = []
        var scriptTags: [String] = []

        if let css = loadStyleCSS(named: preferences.htmlStyleName) {
            styleTags.append(inlineStyle(css))
        }

        let highlighting = syntaxHighlightingTags(preferences: preferences)
        styleTags += highlighting.styles
        scriptTags += highlighting.scripts

        scriptTags += mathJaxTags(preferences: preferences)
        scriptTags += mermaidTags(preferences: preferences)
        scriptTags += taskListTags(preferences: preferences)

        return htmlDocument(
            title: title,
            body: body,
            styleTags: styleTags,
            scriptTags: scriptTags,
            includeViewportMeta: true
        )
    }

    private func syntaxHighlightingTags(preferences: Preferences) -> (styles: [String], scripts: [String]) {
        guard preferences.htmlSyntaxHighlighting else { return ([], []) }

        var styles: [String] = []
        var scripts: [String] = []
        if let prismCSS = loadPrismThemeCSS(named: preferences.htmlHighlightingThemeName) {
            styles.append(inlineStyle(prismCSS))
        }
        if let prismJS = loadPrismCoreJS() {
            scripts.append(inlineScript(prismJS))
        }
        if preferences.htmlLineNumbers {
            if let lineNumCSS = loadPrismPluginCSS(named: "line-numbers") {
                styles.append(inlineStyle(lineNumCSS))
            }
            if let lineNumJS = loadPrismPluginJS(named: "line-numbers") {
                scripts.append(inlineScript(lineNumJS))
            }
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

    private func mermaidTags(preferences: Preferences) -> [String] {
        guard preferences.htmlMermaid else { return [] }

        let mermaidTheme = preferences.htmlStyleName.contains("Dark") ? "dark" : "default"
        let themeScript = inlineScript("window.__fenMermaidTheme = \"\(mermaidTheme)\";")

        return [themeScript] + [
            loadExtensionFile(named: "mermaid.min", ext: "js"),
            loadExtensionFile(named: "mermaid.init", ext: "js"),
        ]
        .compactMap(\.self)
        .map { inlineScript($0) }
    }

    private func taskListTags(preferences: Preferences) -> [String] {
        guard preferences.htmlTaskList,
              let taskJS = loadExtensionFile(named: "tasklist", ext: "js") else { return [] }
        return [inlineScript(taskJS)]
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
            if let prismCSS = loadPrismThemeCSS(named: preferences.htmlHighlightingThemeName) {
                styleTags.append(inlineStyle(prismCSS))
            }
            if let prismJS = loadPrismCoreJS() {
                scriptTags.append(inlineScript(prismJS))
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

    private func loadPrismThemeCSS(named name: String) -> String? {
        loadResourceFile(name: name, ext: "css", subdirectory: "Prism/themes")
    }

    private func loadPrismCoreJS() -> String? {
        loadResourceFile(name: "prism", ext: "js", subdirectory: "Prism")
    }

    private func loadPrismPluginCSS(named name: String) -> String? {
        loadResourceFile(name: "prism-\(name)", ext: "css", subdirectory: "Prism/plugins/\(name)")
    }

    private func loadPrismPluginJS(named name: String) -> String? {
        let minified = loadResourceFile(name: "prism-\(name).min", ext: "js", subdirectory: "Prism/plugins/\(name)")
        return minified ?? loadResourceFile(name: "prism-\(name)", ext: "js", subdirectory: "Prism/plugins/\(name)")
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
}
