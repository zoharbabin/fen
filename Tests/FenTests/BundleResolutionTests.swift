@testable import FenCore
import Highlightr
import Testing

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
        let highlightr = Highlightr()
        #expect(
            highlightr != nil,
            "Highlightr() returned nil — Highlightr_Highlightr.bundle is not resolving correctly"
        )
    }

    @Test("Highlightr lists available themes")
    func highlightrAvailableThemes() {
        guard let highlightr = Highlightr() else {
            Issue.record("Highlightr() returned nil — cannot test availableThemes")
            return
        }
        let themes = highlightr.availableThemes()
        #expect(!themes.isEmpty, "Highlightr.availableThemes() is empty — CSS resources not found in bundle")
        #expect(
            themes.contains("github-dark"),
            "Expected 'github-dark' in Highlightr themes; got \(themes.count) themes"
        )
    }

    @Test("Mermaid uses the dark theme when the preview style is a dark theme")
    func mermaidDarkTheme() {
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("# Hello")
        let prefs = Preferences()
        prefs.htmlMermaid = true
        prefs.htmlStyleName = "GitHub2 Dark"
        let html = HTMLComposer().compose(title: nil, body: rendered.html, preferences: prefs)
        #expect(html.contains("__fenMermaidTheme = \"dark\""))
    }

    @Test("Mermaid uses the default theme when the preview style is a light theme")
    func mermaidLightTheme() {
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("# Hello")
        let prefs = Preferences()
        prefs.htmlMermaid = true
        prefs.htmlStyleName = "GitHub2"
        let html = HTMLComposer().compose(title: nil, body: rendered.html, preferences: prefs)
        #expect(html.contains("__fenMermaidTheme = \"default\""))
    }

    @Test("MathJax is vendored locally, not loaded from a CDN")
    func mathJaxIsVendored() {
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("Inline math: $x+y$")
        let prefs = Preferences()
        prefs.htmlMathJax = true
        prefs.htmlMathJaxInlineDollar = true
        let html = HTMLComposer().compose(title: nil, body: rendered.html, preferences: prefs)
        #expect(!html.contains("cdnjs.cloudflare.com"), "MathJax must not load from a CDN — Fen is local-first")
        #expect(html.contains("window.MathJax"), "Expected the v3 MathJax config object before the library script")
        #expect(html.contains("MathJax"), "Expected the vendored MathJax bundle to be inlined")
    }

    @Test("HTMLComposer.compose returns non-empty HTML with default prefs")
    func htmlComposerCompose() {
        // This exercises the full HTMLComposer resource-loading path (loadStyleCSS,
        // loadHighlightThemeCSS, loadHighlightCoreJS) — the crash point for v0.2.3.
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("# Hello\nWorld")
        let prefs = Preferences()
        let html = HTMLComposer().compose(title: "Test", body: rendered.html, preferences: prefs)
        #expect(html.contains("<h1>"), "HTMLComposer output missing <h1> — rendering failed")
        #expect(html.contains("</html>"), "HTMLComposer output is not a complete HTML document")
    }
}
