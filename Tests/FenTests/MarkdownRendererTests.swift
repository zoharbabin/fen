@testable import FenCore
import Foundation
import Testing

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

    @Test("TOC links target the id actually present on the matching heading")
    func tocLinksMatchHeadingIDs() throws {
        let md = """
        [TOC]

        # First Heading
        ## Second Heading
        """
        var opts = MarkdownRenderer.Options()
        opts.renderTOC = true
        let result = renderer.render(md, options: opts)

        let nsHTML = result.html as NSString
        let fullRange = NSRange(result.html.startIndex..., in: result.html)

        let hrefPattern = ##"href="#([^"]+)""##
        let hrefMatches = try NSRegularExpression(pattern: hrefPattern).matches(in: result.html, range: fullRange)
        let hrefs = hrefMatches.map { nsHTML.substring(with: $0.range(at: 1)) }

        let idPattern = #"<h[1-6] id="([^"]+)""#
        let idMatches = try NSRegularExpression(pattern: idPattern).matches(in: result.html, range: fullRange)
        let ids = idMatches.map { nsHTML.substring(with: $0.range(at: 1)) }

        #expect(!hrefs.isEmpty, "Expected at least one TOC link")
        for href in hrefs {
            #expect(ids.contains(href), "TOC links to #\(href) but no heading has id=\"\(href)\"")
        }
    }

    @Test("Emits data-sourcepos on block elements when enabled")
    func sourcePositions() {
        let md = "# Heading\n\nA paragraph."
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let result = renderer.render(md, options: opts)
        #expect(result.html.contains(#"<h1 data-sourcepos="1:1-1:9">"#))
        #expect(result.html.contains(#"<p data-sourcepos="3:1-3:12">"#))
    }

    @Test("Omits data-sourcepos by default")
    func noSourcePositionsByDefault() {
        let result = renderer.render("# Heading")
        #expect(!result.html.contains("data-sourcepos"))
    }

    @Test("TOC pass preserves data-sourcepos on the rewritten heading tag")
    func tocPreservesSourcePositions() {
        let md = """
        [TOC]

        # First Heading
        """
        var opts = MarkdownRenderer.Options()
        opts.renderTOC = true
        opts.sourcePositions = true
        let result = renderer.render(md, options: opts)
        #expect(result.html.contains(#"<h1 id="first-heading" data-sourcepos="3:1-3:15">"#))
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

    // MARK: - Highlight extension (issue #52)

    @Test("Highlight wraps ==text== in <mark> when enabled")
    func highlightEnabled() {
        var opts = MarkdownRenderer.Options()
        opts.highlight = true
        let result = renderer.render("This is ==important== text.", options: opts)
        #expect(result.html.contains("<mark>important</mark>"))
    }

    @Test("Highlight leaves ==text== untouched when disabled")
    func highlightDisabled() {
        var opts = MarkdownRenderer.Options()
        opts.highlight = false
        let result = renderer.render("This is ==important== text.", options: opts)
        #expect(!result.html.contains("<mark>"))
        #expect(result.html.contains("==important=="))
    }

    @Test("Highlight does not affect an inline code span containing ==text==")
    func highlightSkipsCodeSpan() {
        var opts = MarkdownRenderer.Options()
        opts.highlight = true
        let result = renderer.render("Use `==not highlighted==` here.", options: opts)
        #expect(!result.html.contains("<mark>"))
        #expect(result.html.contains("==not highlighted=="))
    }

    @Test("Highlight does not affect a fenced code block containing ==text==")
    func highlightSkipsCodeBlock() {
        var opts = MarkdownRenderer.Options()
        opts.highlight = true
        let md = """
        ```
        ==not highlighted==
        ```
        """
        let result = renderer.render(md, options: opts)
        #expect(!result.html.contains("<mark>"))
        #expect(result.html.contains("==not highlighted=="))
    }

    @Test("Highlight does not touch a == pair inside an HTML tag's attribute")
    func highlightSkipsTagAttribute() {
        var opts = MarkdownRenderer.Options()
        opts.highlight = true
        let result = renderer.render("[link](https://example.com/?token=abc==def==ghi)", options: opts)
        #expect(!result.html.contains("<mark>"))
        #expect(result.html.contains(#"href="https://example.com/?token=abc==def==ghi""#))
    }

    // MARK: - Footnotes toggle (issue #53)

    @Test("Footnotes render when enabled")
    func footnotesEnabled() {
        var opts = MarkdownRenderer.Options()
        opts.footnotes = true
        let md = """
        Here's a claim.[^1]

        [^1]: The footnote text.
        """
        let result = renderer.render(md, options: opts)
        #expect(result.html.contains("footnote"))
        #expect(result.html.contains("The footnote text."))
    }

    @Test("Footnotes render as literal text when disabled")
    func footnotesDisabled() {
        var opts = MarkdownRenderer.Options()
        opts.footnotes = false
        let md = """
        Here's a claim.[^1]

        [^1]: A footnote body.
        """
        let result = renderer.render(md, options: opts)
        #expect(!result.html.contains("class=\"footnote"))
        #expect(result.html.contains("[^1]"))
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
