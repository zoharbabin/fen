import Foundation
import Testing
import Highlightr
@testable import MacDownCore

@Suite("MarkdownRenderer Tests")
struct MarkdownRendererTests {

    let renderer = MarkdownRenderer()

    @Test("Renders basic paragraph")
    func basicParagraph() {
        let result = renderer.render("Hello, world!")
        #expect(result.html.contains("<p>Hello, world!</p>"))
    }

    @Test("Renders headings")
    func headings() {
        let result = renderer.render("# Heading 1\n## Heading 2")
        #expect(result.html.contains("<h1>"))
        #expect(result.html.contains("<h2>"))
    }

    @Test("Renders bold and italic")
    func boldItalic() {
        let result = renderer.render("**bold** and *italic*")
        #expect(result.html.contains("<strong>bold</strong>"))
        #expect(result.html.contains("<em>italic</em>"))
    }

    @Test("Renders tables with GFM extension")
    func tables() {
        let md = """
        | Header 1 | Header 2 |
        |----------|----------|
        | Cell 1   | Cell 2   |
        """
        var opts = MarkdownRenderer.Options()
        opts.tables = true
        let result = renderer.render(md, options: opts)
        #expect(result.html.contains("<table>"))
        #expect(result.html.contains("<th>"))
    }

    @Test("Renders strikethrough")
    func strikethrough() {
        var opts = MarkdownRenderer.Options()
        opts.strikethrough = true
        let result = renderer.render("~~deleted~~", options: opts)
        #expect(result.html.contains("<del>"))
    }

    @Test("Renders autolinks")
    func autolinks() {
        var opts = MarkdownRenderer.Options()
        opts.autolink = true
        let result = renderer.render("Visit https://example.com today", options: opts)
        #expect(result.html.contains("<a href"))
    }

    @Test("Renders fenced code blocks")
    func fencedCode() {
        let md = """
        ```swift
        let x = 42
        ```
        """
        let result = renderer.render(md)
        #expect(result.html.contains("<code"))
    }

    @Test("Extracts YAML front matter")
    func frontMatter() {
        let md = """
        ---
        title: My Document
        author: Test
        ---
        # Content
        """
        var opts = MarkdownRenderer.Options()
        opts.detectFrontMatter = true
        let result = renderer.render(md, options: opts)
        #expect(result.title == "My Document")
        #expect(!result.html.contains("---"))
        #expect(result.html.contains("<h1>"))
    }

    @Test("Skips front matter when disabled")
    func noFrontMatter() {
        let md = """
        ---
        title: My Document
        ---
        # Content
        """
        var opts = MarkdownRenderer.Options()
        opts.detectFrontMatter = false
        let result = renderer.render(md, options: opts)
        #expect(result.title == nil)
    }

    @Test("Replaces TOC marker")
    func toc() {
        let md = """
        [TOC]

        # First
        ## Second
        """
        var opts = MarkdownRenderer.Options()
        opts.renderTOC = true
        let result = renderer.render(md, options: opts)
        #expect(result.html.contains("toc-h"))
        #expect(!result.html.contains("[TOC]"))
    }

    @Test("Handles empty input")
    func emptyInput() {
        let result = renderer.render("")
        #expect(result.html.isEmpty || result.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Renders task lists")
    func taskLists() {
        let md = """
        - [x] Done
        - [ ] Not done
        """
        var opts = MarkdownRenderer.Options()
        opts.taskList = true
        let result = renderer.render(md, options: opts)
        #expect(result.html.contains("checked"))
    }
}

@Suite("Theme Parser Tests")
struct ThemeParserTests {

    @Test("Parses editor theme")
    func parseTheme() {
        let content = """
        editor
        foreground: cccccc
        background: 2d2d2d
        caret: cc99cc

        H1
        foreground: 66cccc
        font-style: bold
        font-size: 24px
        """
        let theme = EditorTheme.parse(content, name: "Test")
        #expect(theme.name == "Test")
        #expect(theme.elementStyles["H1"] != nil)
        #expect(theme.elementStyles["H1"]?.fontStyle == .bold)
        #expect(theme.elementStyles["H1"]?.fontSize == 24)
    }

    @Test("Handles empty theme content")
    func emptyTheme() {
        let theme = EditorTheme.parse("", name: "Empty")
        #expect(theme.name == "Empty")
        #expect(theme.elementStyles.isEmpty)
    }
}

// MARK: - Bundle Resolution Tests
//
// These tests guard against the Bundle.main.bundleURL vs Bundle.main.resourceURL
// failure mode that caused crashes in v0.2.0–v0.2.3. The SPM-generated
// Bundle.module accessor resolves against bundleURL (the .app root), but signed
// .apps place resource bundles inside Contents/Resources/ (resourceURL). Our
// coreBundle and Highlightr's init both resolve against resourceURL first.
//
// In swift test runs, Bundle.main.resourceURL points to the .build/ product
// directory where SPM also writes the bundles, so the tests exercise the same
// path the production code uses (just against .build/ instead of .app).

@Suite("Bundle Resolution Tests")
struct BundleResolutionTests {

    @Test("coreBundle resolves a Styles CSS resource")
    func coreBundleStyles() {
        // coreBundle must find at least one style; "GitHub2.css" ships with the app.
        let url = coreBundle.url(forResource: "GitHub2", withExtension: "css", subdirectory: "Styles")
        #expect(url != nil, "coreBundle cannot find Styles/GitHub2.css — bundle resolution is broken")
    }

    @Test("coreBundle resolves a Themes style resource")
    func coreBundleThemes() {
        // "Mou Night" ships with the app; if loading fails the theme picker is empty.
        let url = coreBundle.url(forResource: "Mou Night", withExtension: "style", subdirectory: "Themes")
        #expect(url != nil, "coreBundle cannot find Themes/Mou Night.style — bundle resolution is broken")
    }

    @Test("coreBundle resolves the Default HTML template")
    func coreBundleTemplate() {
        let url = coreBundle.url(forResource: "Default", withExtension: "handlebars", subdirectory: "Templates")
        #expect(url != nil, "coreBundle cannot find Templates/Default.handlebars — bundle resolution is broken")
    }

    @Test("availableThemes returns bundled theme names")
    func coreBundleAvailableThemes() {
        let themes = EditorTheme.availableThemes()
        #expect(!themes.isEmpty, "EditorTheme.availableThemes() is empty — coreBundle cannot enumerate Themes/")
        #expect(themes.contains("Mou Night"), "Expected 'Mou Night' in availableThemes; got: \(themes)")
    }

    @Test("availablePreviewStyles returns bundled CSS names")
    func coreBundlePreviewStyles() {
        let styles = HTMLComposer.availablePreviewStyles()
        #expect(!styles.isEmpty, "HTMLComposer.availablePreviewStyles() is empty — coreBundle cannot enumerate Styles/")
        #expect(styles.contains("GitHub2"), "Expected 'GitHub2' in availablePreviewStyles; got: \(styles)")
    }

    @Test("Highlightr initializes and finds highlight.min.js")
    func highlightrBundleResolution() {
        // Highlightr() returns nil when its bundle lookup fails (it calls
        // bundle.path(forResource:ofType:) which returns nil, causing init to
        // return nil). This is the exact failure path that crashed v0.2.0–v0.2.2.
        let h = Highlightr()
        #expect(h != nil, "Highlightr() returned nil — Highlightr_Highlightr.bundle is not resolving correctly")
    }

    @Test("Highlightr lists available themes")
    func highlightrAvailableThemes() {
        guard let h = Highlightr() else {
            Issue.record("Highlightr() returned nil — cannot test availableThemes")
            return
        }
        let themes = h.availableThemes()
        #expect(!themes.isEmpty, "Highlightr.availableThemes() is empty — CSS resources not found in bundle")
        #expect(themes.contains("github-dark"), "Expected 'github-dark' in Highlightr themes; got \(themes.count) themes")
    }

    @Test("HTMLComposer.compose returns non-empty HTML with default prefs")
    func htmlComposerCompose() {
        // This exercises the full HTMLComposer resource-loading path (loadStyleCSS,
        // loadPrismThemeCSS, loadPrismCoreJS) — the crash point for v0.2.3.
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("# Hello\nWorld")
        let prefs = Preferences()
        let html = HTMLComposer().compose(title: "Test", body: rendered.html, preferences: prefs)
        #expect(html.contains("<h1>"), "HTMLComposer output missing <h1> — rendering failed")
        #expect(html.contains("</html>"), "HTMLComposer output is not a complete HTML document")
    }
}

@Suite("Preferences Tests")
struct PreferencesTests {

    // Each test gets a fresh isolated UserDefaults suite so tests cannot
    // contaminate each other or the app's real UserDefaults.
    private static func isolated() -> (Preferences, UserDefaults) {
        let suiteName = "test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        return (Preferences(defaults: ud), ud)
    }

    @Test("Default values are correct")
    func defaults() {
        let (prefs, _) = Self.isolated()
        #expect(prefs.editorFontName == "Menlo-Regular")
        #expect(prefs.editorFontSize == 14)
        #expect(prefs.editorStyleName == "xcode")
        #expect(prefs.htmlStyleName == "GitHub2")
        #expect(prefs.extensionTables == true)
        #expect(prefs.extensionAutolink == true)
        #expect(prefs.extensionStrikethrough == true)
        #expect(prefs.htmlSyntaxHighlighting == true)
        #expect(prefs.htmlDetectFrontMatter == true)
        #expect(prefs.htmlTaskList == true)
    }

    @Test("Stored properties immediately reflect assigned values")
    func storedPropertyReflectsAssignment() {
        // Regression: when properties were computed (delegating to UserDefaults),
        // @Observable could not track changes — pickers reverted after selection.
        let (prefs, _) = Self.isolated()

        prefs.htmlStyleName = "GitHub2 Dark"
        #expect(prefs.htmlStyleName == "GitHub2 Dark")

        prefs.htmlStyleName = "Clearness"
        #expect(prefs.htmlStyleName == "Clearness")
    }

    @Test("renderRevision increments on render-affecting changes")
    func renderRevisionIncrements() {
        // Regression: settings only took effect after app restart because
        // SplitEditorView had no way to observe preference changes.
        // renderRevision is the stored @Observable sentinel it watches.
        let (prefs, _) = Self.isolated()
        let base = prefs.renderRevision

        prefs.htmlStyleName = "Clearness Dark"
        #expect(prefs.renderRevision == base + 1)

        prefs.htmlSyntaxHighlighting = !prefs.htmlSyntaxHighlighting
        #expect(prefs.renderRevision == base + 2)

        prefs.extensionTables = !prefs.extensionTables
        #expect(prefs.renderRevision == base + 3)

        prefs.extensionStrikethrough = !prefs.extensionStrikethrough
        #expect(prefs.renderRevision == base + 4)

        prefs.extensionAutolink = !prefs.extensionAutolink
        #expect(prefs.renderRevision == base + 5)

        prefs.htmlMathJax = !prefs.htmlMathJax
        #expect(prefs.renderRevision == base + 6)

        prefs.htmlMermaid = !prefs.htmlMermaid
        #expect(prefs.renderRevision == base + 7)

        prefs.htmlTaskList = !prefs.htmlTaskList
        #expect(prefs.renderRevision == base + 8)

        prefs.htmlHardWrap = !prefs.htmlHardWrap
        #expect(prefs.renderRevision == base + 9)

        prefs.htmlRendersTOC = !prefs.htmlRendersTOC
        #expect(prefs.renderRevision == base + 10)

        prefs.htmlDetectFrontMatter = !prefs.htmlDetectFrontMatter
        #expect(prefs.renderRevision == base + 11)

        prefs.extensionSmartyPants = !prefs.extensionSmartyPants
        #expect(prefs.renderRevision == base + 12)

        prefs.htmlHighlightingThemeName = "github-dark"
        #expect(prefs.renderRevision == base + 13)

        prefs.htmlLineNumbers = !prefs.htmlLineNumbers
        #expect(prefs.renderRevision == base + 14)

        prefs.htmlMathJaxInlineDollar = !prefs.htmlMathJaxInlineDollar
        #expect(prefs.renderRevision == base + 15)
    }

    @Test("renderRevision does not increment for editor-only changes")
    func renderRevisionStableForEditorPrefs() {
        let (prefs, _) = Self.isolated()
        let base = prefs.renderRevision

        prefs.editorFontSize = prefs.editorFontSize + 1
        prefs.editorStyleName = "github-dark"
        prefs.editorScrollsPastEnd = !prefs.editorScrollsPastEnd
        prefs.editorShowWordCount = !prefs.editorShowWordCount
        prefs.editorConvertTabs = !prefs.editorConvertTabs
        #expect(prefs.renderRevision == base)
    }
}
