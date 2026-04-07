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

        // Base preview stylesheet
        if let css = loadStyleCSS(named: preferences.htmlStyleName) {
            styleTags.append(inlineStyle(css))
        }

        // Syntax highlighting via Prism
        if preferences.htmlSyntaxHighlighting {
            if let prismCSS = loadPrismThemeCSS(named: preferences.htmlHighlightingThemeName) {
                styleTags.append(inlineStyle(prismCSS))
            }
            if let prismJS = loadPrismCoreJS() {
                scriptTags.append(inlineScript(prismJS))
            }
            // Line numbers plugin
            if preferences.htmlLineNumbers {
                if let lineNumCSS = loadPrismPluginCSS(named: "line-numbers") {
                    styleTags.append(inlineStyle(lineNumCSS))
                }
                if let lineNumJS = loadPrismPluginJS(named: "line-numbers") {
                    scriptTags.append(inlineScript(lineNumJS))
                }
            }
        }

        // MathJax
        if preferences.htmlMathJax {
            let mathjaxCDN = "https://cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.3/MathJax.js?config=TeX-AMS-MML_HTMLorMML"
            scriptTags.append(externalScript(mathjaxCDN))
            if preferences.htmlMathJaxInlineDollar {
                let config = """
                <script type="text/x-mathjax-config">
                MathJax.Hub.Config({
                    tex2jax: { inlineMath: [['$','$'], ['\\\\(','\\\\)']] }
                });
                </script>
                """
                scriptTags.append(config)
            }
        }

        // Mermaid
        if preferences.htmlMermaid {
            if let mermaidJS = loadExtensionFile(named: "mermaid.min", ext: "js") {
                scriptTags.append(inlineScript(mermaidJS))
            }
            if let initJS = loadExtensionFile(named: "mermaid.init", ext: "js") {
                scriptTags.append(inlineScript(initJS))
            }
        }

        // Task list interactivity
        if preferences.htmlTaskList {
            if let taskJS = loadExtensionFile(named: "tasklist", ext: "js") {
                scriptTags.append(inlineScript(taskJS))
            }
        }

        // Build the HTML document from template
        let titleTag = title.map { "<title>\($0)</title>" } ?? ""
        let styleBlock = styleTags.joined(separator: "\n")
        let scriptBlock = scriptTags.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">
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
        let exportPrefs = preferences
        // For export, we might want to adjust preferences
        // but for simplicity, delegate to compose with filtered options
        var styleTags: [String] = []
        var scriptTags: [String] = []

        if includeStyles {
            if let css = loadStyleCSS(named: exportPrefs.htmlStyleName) {
                styleTags.append(inlineStyle(css))
            }
        }

        if includeHighlighting && exportPrefs.htmlSyntaxHighlighting {
            if let prismCSS = loadPrismThemeCSS(named: exportPrefs.htmlHighlightingThemeName) {
                styleTags.append(inlineStyle(prismCSS))
            }
            if let prismJS = loadPrismCoreJS() {
                scriptTags.append(inlineScript(prismJS))
            }
        }

        let titleTag = title.map { "<title>\($0)</title>" } ?? ""
        let styleBlock = styleTags.joined(separator: "\n")
        let scriptBlock = scriptTags.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
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
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
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

    private func externalScript(_ url: String) -> String {
        "<script src=\"\(url)\"></script>"
    }

    // MARK: - Available Styles

    public static func availablePreviewStyles() -> [String] {
        guard let url = Bundle.main.url(forResource: "Styles", withExtension: nil),
              let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return [] }
        return contents
            .filter { $0.pathExtension == "css" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
