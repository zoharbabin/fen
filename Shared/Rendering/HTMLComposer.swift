import Foundation
import SwiftUI

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
        sourceLineOffset: Int = 0,
        documentOverrides: DocumentPreviewOverrides = .none
    ) -> String {
        var styleTags: [String] = []
        var scriptTags: [String] = []

        let effectiveStyleName = Self.resolveEffectiveStyleName(
            preferences: preferences,
            documentOverrides: documentOverrides
        )
        if let css = loadStyleCSS(named: effectiveStyleName) {
            styleTags.append(inlineStyle(css))
        }

        styleTags.append(inlineStyle(fontScaleCSS(preferences: preferences)))
        styleTags.append(inlineStyle(Self.listMarkerCSS))
        styleTags.append(inlineStyle(Self.alertsCSS))

        let highlighting = syntaxHighlightingTags(preferences: preferences)
        styleTags += highlighting.styles
        scriptTags += highlighting.scripts

        scriptTags += mathJaxTags(preferences: preferences)

        let mermaid = mermaidTags(preferences: preferences, effectiveStyleName: effectiveStyleName)
        styleTags += mermaid.styles
        scriptTags += mermaid.scripts

        scriptTags += taskListTags(preferences: preferences)
        scriptTags.append(inlineScript(Self.listMarkerStartJS))

        let copyButton = copyButtonTags(preferences: preferences)
        styleTags += copyButton.styles
        scriptTags += copyButton.scripts

        scriptTags += scrollSyncTags(sourceLineCount: sourceLineCount, sourceLineOffset: sourceLineOffset)

        if preferences.customCSSEnabled,
           !preferences.customCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            styleTags.append(inlineStyle(Self.sanitizeCustomCSS(preferences.customCSS)))
        }

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

    private func mermaidTags(
        preferences: Preferences,
        effectiveStyleName: String
    ) -> (styles: [String], scripts: [String]) {
        guard preferences.htmlMermaid else { return ([], []) }

        let mermaidTheme = effectiveStyleName.contains("Dark") ? "dark" : "default"
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

    private func copyButtonTags(preferences: Preferences) -> (styles: [String], scripts: [String]) {
        guard preferences.htmlCopyButton else { return ([], []) }

        let styles = [loadExtensionFile(named: "copy-button", ext: "css")]
            .compactMap(\.self)
            .map { inlineStyle($0) }
        let scripts = [loadExtensionFile(named: "copy-button", ext: "js")]
            .compactMap(\.self)
            .map { inlineScript($0) }
        return (styles, scripts)
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

    /// Compose HTML suitable for export (optionally without styles/scripts). `documentOverrides`
    /// (issue #85) lets a document's own `fen:` front matter substitute its theme for
    /// `preferences.htmlStyleName`, mirroring `compose`'s own `documentOverrides` parameter.
    public func composeForExport(
        title: String?,
        body: String,
        preferences: Preferences,
        includeStyles: Bool,
        includeHighlighting: Bool,
        documentOverrides: DocumentPreviewOverrides = .none
    ) -> String {
        let (styleTags, scriptTags) = exportStyleAndScriptTags(
            preferences: preferences,
            includeStyles: includeStyles,
            includeHighlighting: includeHighlighting,
            documentOverrides: documentOverrides
        )
        return htmlDocument(
            title: title, body: body, styleTags: styleTags, scriptTags: scriptTags, includeViewportMeta: false
        )
    }

    /// Compose HTML for paginated PDF export (issue #30) or printing (issue #32) -- the same
    /// style/script assembly `composeForExport` uses (always with styles and syntax
    /// highlighting, since a PDF/printout has no live preference toggle to react to), plus
    /// `print.css`'s break-avoidance rules so content never gets sliced across a page boundary.
    /// Page margins come from `NSPrintInfo`/`UIPrintPageRenderer` (the platform print pipeline),
    /// not CSS, so the two never double up. Uses `preferences.printStyleName` in place of
    /// `htmlStyleName` when set (issue #82), so a document can be previewed in one theme but
    /// printed/exported in another -- e.g. a dark on-screen preview with a light printout.
    /// `documentOverrides` (issue #85) takes precedence over both when its `styleName` is set.
    public func composeForPrint(
        title: String?,
        body: String,
        preferences: Preferences,
        documentOverrides: DocumentPreviewOverrides = .none
    ) -> String {
        var (styleTags, scriptTags) = exportStyleAndScriptTags(
            preferences: preferences,
            includeStyles: true,
            includeHighlighting: true,
            styleNameOverride: preferences.printStyleName,
            documentOverrides: documentOverrides
        )
        if let printCSS = loadExtensionFile(named: "print", ext: "css") {
            styleTags.append(inlineStyle(printCSS))
        }
        return htmlDocument(
            title: title, body: body, styleTags: styleTags, scriptTags: scriptTags, includeViewportMeta: false
        )
    }

    /// Shared style/script-tag assembly for `composeForExport` and `composeForPrint` (rule 5.1)
    /// -- the theme stylesheet, optional syntax highlighting, and optional user custom CSS every
    /// non-live-preview HTML document needs. `styleNameOverride` lets `composeForPrint` substitute
    /// `printStyleName` for `htmlStyleName` (issue #82); `composeForExport` never passes one, since
    /// HTML export has no separate theme setting. `documentOverrides.styleName` (issue #85), when
    /// set, wins over both -- the same precedence `resolveEffectiveStyleName` already uses for
    /// `compose` (rule 5.1: one theme-resolution order, not a second one here).
    private func exportStyleAndScriptTags(
        preferences: Preferences,
        includeStyles: Bool,
        includeHighlighting: Bool,
        styleNameOverride: String? = nil,
        documentOverrides: DocumentPreviewOverrides = .none
    ) -> (styleTags: [String], scriptTags: [String]) {
        var styleTags: [String] = []
        var scriptTags: [String] = []

        let resolvedStyleName = documentOverrides.styleName ?? styleNameOverride ?? preferences.htmlStyleName
        if includeStyles, let css = loadStyleCSS(named: resolvedStyleName) {
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

        if preferences.customCSSEnabled,
           !preferences.customCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            styleTags.append(inlineStyle(Self.sanitizeCustomCSS(preferences.customCSS)))
        }

        return (styleTags, scriptTags)
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

    // MARK: - Appearance Resolution (issue #25)

    /// Maps each light style to its dark counterpart and vice versa, covering the 3 pairs that
    /// already exist by filename convention. `GitHub` has no dark counterpart and is
    /// deliberately absent -- `resolveEffectiveStyleName` falls back to the original name
    /// unchanged for any style with no entry here (rule 3.1).
    static let styleAppearancePairs: [String: String] = [
        "Clearness": "Clearness Dark",
        "Clearness Dark": "Clearness",
        "GitHub2": "GitHub2 Dark",
        "GitHub2 Dark": "GitHub2",
        "Solarized (Light)": "Solarized (Dark)",
        "Solarized (Dark)": "Solarized (Light)",
    ]

    /// Resolves which CSS file to actually load, given the user's selected `htmlStyleName`,
    /// the manual appearance override, and the live system appearance. A style whose own
    /// darkness (via the existing `.contains("Dark")` convention) already matches what's
    /// wanted is returned unchanged; otherwise its pair is looked up. A style with no pair
    /// (`GitHub`) is returned unchanged regardless of what's wanted (rule 3.1), and an
    /// unrecognized style name is likewise returned unchanged (rule 3.2) -- this function
    /// never fails, throws, or returns an empty string.
    static func resolveEffectiveStyleName(
        preferences: Preferences,
        documentOverrides: DocumentPreviewOverrides = .none
    ) -> String {
        let wantsDark: Bool = switch preferences.previewAppearanceMode {
        case .system: preferences.systemPrefersDarkAppearance
        case .light: false
        case .dark: true
        }
        let styleName = documentOverrides.styleName ?? preferences.htmlStyleName
        guard styleName.contains("Dark") != wantsDark else { return styleName }
        return styleAppearancePairs[styleName] ?? styleName
    }

    // MARK: - Custom CSS (issue #26)

    /// The largest custom CSS contribution `compose`/`composeForExport` will inline, regardless
    /// of how much text `Preferences.customCSS` holds -- a defensive bound against pathological
    /// input, not a feature limit any real stylesheet is expected to hit (rule 2.2).
    static let customCSSCharacterLimit = 8000

    /// `@import`/non-`data:` `url(...)` regexes for `sanitizeCustomCSS`, compiled once. `try?`
    /// rather than `try!` (matching `MarkdownRenderer+Alerts.swift`'s convention): the patterns
    /// are compile-time literals that always compile, but `sanitizeCustomCSS` still degrades to
    /// returning the untouched, truncated input rather than crashing if that ever changed.
    private static let importRuleRegex = try? NSRegularExpression(
        pattern: #"@import\s+[^;]*;"#, options: [.caseInsensitive]
    )
    private static let nonDataURLRegex = try? NSRegularExpression(
        pattern: #"url\(\s*(?!['"]?data:)[^)]*\)"#, options: [.caseInsensitive]
    )
    /// Matches `</style` (with or without a closing `>`), case-insensitively -- `inlineStyle`
    /// inlines this text directly inside a real `<style>` tag with no HTML escaping, so any
    /// occurrence would close the style block early and let the rest of the string be parsed as
    /// live markup/script in the preview `WKWebView`.
    private static let styleCloseTagRegex = try? NSRegularExpression(
        pattern: #"</style"#, options: [.caseInsensitive]
    )

    /// Strips every `@import` rule, every `url(...)` reference whose scheme isn't `data:`, and
    /// any `</style` breakout sequence, so user-supplied CSS can never trigger a network fetch
    /// (rule 2.1) or escape the `<style>` tag `inlineStyle` wraps it in to run as live HTML/JS in
    /// the preview's WKWebView -- Fen's trust model is local-first with zero third-party runtime
    /// network loads, and custom CSS is the first feature where externally-authored text is
    /// inlined into the preview's WKWebView, so this is the one new content-injection point that
    /// needs its own guard. Operates as plain text substitution, never a full CSS parse, so
    /// malformed input can't throw (rule 3.2). Also enforces `customCSSCharacterLimit` (rule 2.2)
    /// as the final step.
    static func sanitizeCustomCSS(_ css: String) -> String {
        let truncated = String(css.prefix(customCSSCharacterLimit))
        guard let importRuleRegex, let nonDataURLRegex, let styleCloseTagRegex else { return truncated }
        var result = truncated as NSString
        result = importRuleRegex.stringByReplacingMatches(
            in: result as String, range: NSRange(location: 0, length: result.length), withTemplate: ""
        ) as NSString
        result = nonDataURLRegex.stringByReplacingMatches(
            in: result as String, range: NSRange(location: 0, length: result.length), withTemplate: ""
        ) as NSString
        result = styleCloseTagRegex.stringByReplacingMatches(
            in: result as String, range: NSRange(location: 0, length: result.length), withTemplate: ""
        ) as NSString
        return result as String
    }

    /// `body { background-color: ...; color: ...; }` regexes for `themeSwatchColors`. Anchored
    /// to the start of a line (`^body`, multiline mode) so a compound selector like
    /// `html body { ... }` -- a different, more specific rule -- never matches as if it were the
    /// bare `body` rule; every bundled theme's own standalone `body {` rule starts at column 0.
    private static let backgroundColorRegex = try? NSRegularExpression(
        pattern: #"^body\s*\{[^}]*background-color:\s*([^;}\s]+)"#, options: [.caseInsensitive, .anchorsMatchLines]
    )
    private static let textColorRegex = try? NSRegularExpression(
        pattern: #"^body\s*\{[^}]*(?<!background-)color:\s*([^;}\s]+)"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    /// Parses a bundled theme's own `body { background-color: ...; color: ...; }` declaration
    /// into a small swatch for the settings picker (issue #26), without a full CSS parser.
    /// `color` is optional and defaults to black (the browser's own UA default for unset text
    /// color) -- `GitHub2.css`'s `body` rule legitimately never sets one. Returns `nil` (never
    /// throws) when a theme's `body` rule doesn't declare a background in a form this simple
    /// regex can find -- e.g. `Solarized (Light).css`/`Solarized (Dark).css` declare `body`'s
    /// background via a separate `html body { background-color: ... }` override rather than in
    /// the `body` rule itself, so those two themes show no swatch (rule 3.3).
    static func themeSwatchColors(cssFileName: String) -> (background: Color, text: Color)? {
        guard let backgroundColorRegex, let css = HTMLComposer().loadStyleCSS(named: cssFileName) else { return nil }
        guard let background = firstCaptureColor(backgroundColorRegex, in: css) else { return nil }
        let text = textColorRegex.flatMap { firstCaptureColor($0, in: css) } ?? .black
        return (background, text)
    }

    private static func firstCaptureColor(_ regex: NSRegularExpression, in css: String) -> Color? {
        let nsCSS = css as NSString
        guard let match = regex.firstMatch(in: css, range: NSRange(location: 0, length: nsCSS.length)),
              match.numberOfRanges > 1
        else { return nil }
        let value = nsCSS.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if let hexColor = PlatformColor(hex: value) {
            return Color(hexColor)
        }
        if value.caseInsensitiveCompare("white") == .orderedSame {
            return .white
        }
        if value.caseInsensitiveCompare("black") == .orderedSame {
            return .black
        }
        return nil
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
