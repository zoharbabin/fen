import Testing
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

@Suite("Preferences Tests")
struct PreferencesTests {

    @Test("Default values are correct")
    func defaults() {
        let prefs = Preferences.shared
        #expect(prefs.editorFontName == "Menlo-Regular")
        #expect(prefs.editorFontSize == 14)
        #expect(prefs.editorStyleName == "xcode")
        #expect(prefs.htmlStyleName == "GitHub2")
    }
}
