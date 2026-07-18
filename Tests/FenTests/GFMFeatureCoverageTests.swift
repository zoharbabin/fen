@testable import FenCore
import Testing

/// End-to-end WKWebView verification of every GFM/Markdown capability Fen supports,
/// following the pattern in PreviewSchemeHandlerVerifyTest.swift: render the real
/// pipeline, load it into a WKWebView, and assert against the actual rendered DOM
/// rather than raw HTML strings.
@Suite("GFM feature coverage")
struct GFMFeatureCoverageTests {
    @Test("Headers: atx and setext both produce heading elements")
    @MainActor
    func headers() async throws {
        let md = """
        Setext H1
        =========

        # ATX H1
        ###### ATX H6
        """
        let webView = try await renderPreviewWebView(markdown: md)
        let levels = try await webView.evaluateJavaScript(
            "[1,6].every(function(l){ return document.querySelectorAll('h'+l).length > 0; })"
        )
        #expect((levels as? Bool) == true, "Expected both setext-derived <h1> and atx <h6> to render")
    }

    @Test("Paragraphs: soft line breaks collapse, hard breaks (two trailing spaces) insert <br>")
    @MainActor
    func paragraphsAndLineBreaks() async throws {
        let md = "soft one\nsoft two\n\nhard one  \nhard two"
        let webView = try await renderPreviewWebView(markdown: md)
        let hasBR = try await webView.evaluateJavaScript("document.querySelectorAll('br').length")
        #expect((hasBR as? Int) == 1, "Expected exactly one <br> from the hard-break paragraph")
    }

    @Test("Emphasis: bold, italic, and combined render as strong/em; underscores don't trigger mid-word")
    @MainActor
    func emphasis() async throws {
        let md = "**bold** *italic* ***both*** un*mid*word un_not_mid"
        let webView = try await renderPreviewWebView(markdown: md)
        let strongCount = try await webView.evaluateJavaScript("document.querySelectorAll('strong').length")
        let emCount = try await webView.evaluateJavaScript("document.querySelectorAll('em').length")
        let text = try await webView.evaluateJavaScript("document.body.textContent")
        #expect((strongCount as? Int) ?? 0 >= 2, "Expected strong for **bold** and ***both***")
        #expect((emCount as? Int) ?? 0 >= 2, "Expected em for *italic* and ***both***")
        #expect((text as? String)?.contains("un_not_mid") == true, "Underscore mid-word must not trigger emphasis")
    }

    @Test("Blockquotes: nest correctly")
    @MainActor
    func blockquotes() async throws {
        let md = "> level one\n>\n> > level two"
        let webView = try await renderPreviewWebView(markdown: md)
        let nested = try await webView.evaluateJavaScript(
            "!!document.querySelector('blockquote blockquote')"
        )
        #expect((nested as? Bool) == true, "Expected a nested <blockquote> inside a <blockquote>")
    }

    @Test("Lists: ordered and unordered render with correct item counts")
    @MainActor
    func lists() async throws {
        let md = "* a\n* b\n* c\n\n1. x\n2. y"
        let webView = try await renderPreviewWebView(markdown: md)
        let ulItems = try await webView.evaluateJavaScript("document.querySelectorAll('ul > li').length")
        let olItems = try await webView.evaluateJavaScript("document.querySelectorAll('ol > li').length")
        #expect((ulItems as? Int) == 3)
        #expect((olItems as? Int) == 2)
    }

    @Test("Task lists (GFM): checkboxes render, checked state matches source, inline with text")
    @MainActor
    func taskLists() async throws {
        let md = "- [x] done\n- [ ] not done"
        var opts = MarkdownRenderer.Options()
        opts.taskList = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let checkedCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('input[type=checkbox]:checked').length"
        )
        let uncheckedCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('input[type=checkbox]:not(:checked)').length"
        )
        #expect((checkedCount as? Int) == 1)
        #expect((uncheckedCount as? Int) == 1)
    }

    @Test("Horizontal rules: all three markers (---, ***, ___) render as <hr>")
    @MainActor
    func horizontalRules() async throws {
        let md = "text\n\n---\n\n***\n\n___\n\nmore"
        let webView = try await renderPreviewWebView(markdown: md)
        let hrCount = try await webView.evaluateJavaScript("document.querySelectorAll('hr').length")
        #expect((hrCount as? Int) == 3)
    }

    @Test("Links and images: inline, reference-style, and image all resolve")
    @MainActor
    func linksAndImages() async throws {
        let md = """
        [inline](https://fen.md)

        [ref][id]

        [id]: https://fen.md

        ![alt text](https://fen.md/x.png)
        """
        var opts = MarkdownRenderer.Options()
        opts.autolink = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let linkCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('a[href=\"https://fen.md\"]').length"
        )
        let imgAlt = try await webView.evaluateJavaScript(
            "document.querySelector('img') ? document.querySelector('img').alt : null"
        )
        #expect((linkCount as? Int) == 2, "Expected both the inline and reference-style link to resolve")
        #expect((imgAlt as? String) == "alt text")
    }

    @Test("Tables (GFM): headers, rows, and column alignment all render")
    @MainActor
    func tables() async throws {
        let md = "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |"
        var opts = MarkdownRenderer.Options()
        opts.tables = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let thCount = try await webView.evaluateJavaScript("document.querySelectorAll('th').length")
        let tdCount = try await webView.evaluateJavaScript("document.querySelectorAll('td').length")
        let alignments = try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('th')).map(function(el){return el.align;}).join(',')"
        )
        #expect((thCount as? Int) == 3)
        #expect((tdCount as? Int) == 3)
        #expect((alignments as? String) == "left,center,right")
    }

    @Test("Strikethrough (GFM): renders as <del>")
    @MainActor
    func strikethrough() async throws {
        let md = "~~struck~~"
        var opts = MarkdownRenderer.Options()
        opts.strikethrough = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let text = try await webView.evaluateJavaScript(
            "document.querySelector('del') ? document.querySelector('del').textContent : null"
        )
        #expect((text as? String) == "struck")
    }

    @Test("Autolinks (GFM): bare URLs, www-hosts, and emails all become links")
    @MainActor
    func autolinks() async throws {
        let md = "https://fen.md and www.fen.md and hello@fen.md"
        var opts = MarkdownRenderer.Options()
        opts.autolink = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let bareLink = try await webView.evaluateJavaScript(
            "!!document.querySelector('a[href=\"https://fen.md\"]')"
        )
        let wwwLink = try await webView.evaluateJavaScript(
            "!!document.querySelector('a[href=\"http://www.fen.md\"]')"
        )
        let mailLink = try await webView.evaluateJavaScript(
            "!!document.querySelector('a[href=\"mailto:hello@fen.md\"]')"
        )
        #expect((bareLink as? Bool) == true)
        #expect((wwwLink as? Bool) == true)
        #expect((mailLink as? Bool) == true)
    }

    @Test("Footnotes: reference links to a definition rendered in a footnotes section")
    @MainActor
    func footnotes() async throws {
        let md = "Footnote.[^1]\n\n[^1]: Note text."
        let webView = try await renderPreviewWebView(markdown: md)
        let hasRef = try await webView.evaluateJavaScript(
            "!!document.querySelector('a[data-footnote-ref]')"
        )
        let hasBackref = try await webView.evaluateJavaScript(
            "!!document.querySelector('a[data-footnote-backref]')"
        )
        let noteText = try await webView.evaluateJavaScript("""
        (function () {
            var section = document.querySelector('section.footnotes');
            return !!section && section.textContent.indexOf('Note text.') >= 0;
        })();
        """)
        #expect((hasRef as? Bool) == true, "Expected an inline footnote reference link")
        #expect((hasBackref as? Bool) == true, "Expected a backreference link from the footnote definition")
        #expect((noteText as? Bool) == true, "Expected the footnote definition text to render")
    }

    @Test("Backslash escapes: escaped emphasis/code markers render as literal characters")
    @MainActor
    func backslashEscapes() async throws {
        let md = #"\*Not emphasis\*, \`not a code span\`"#
        let webView = try await renderPreviewWebView(markdown: md)
        let hasEm = try await webView.evaluateJavaScript("!!document.querySelector('em')")
        let hasCode = try await webView.evaluateJavaScript("!!document.querySelector('code')")
        let text = try await webView.evaluateJavaScript("document.body.textContent")
        #expect((hasEm as? Bool) == false, "Escaped asterisks must not produce <em>")
        #expect((hasCode as? Bool) == false, "Escaped backticks must not produce <code>")
        #expect((text as? String)?.contains("*Not emphasis*") == true)
    }

    @Test("YAML front matter: stripped from body and title flows into the composed document")
    @MainActor
    func frontMatter() async throws {
        let md = "---\ntitle: My Doc\n---\n\n# Body"
        var opts = MarkdownRenderer.Options()
        opts.detectFrontMatter = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let title = try await webView.evaluateJavaScript("document.title")
        let bodyContainsFrontMatter = try await webView.evaluateJavaScript(
            "document.body.textContent.indexOf('title: My Doc') >= 0"
        )
        #expect((title as? String) == "My Doc")
        #expect((bodyContainsFrontMatter as? Bool) == false, "Front matter must not leak into the rendered body")
    }

    @Test("[TOC] marker: replaced with a list of links that target the actual heading ids")
    @MainActor
    func tableOfContents() async throws {
        let md = "[TOC]\n\n# First Heading\n## Second Heading"
        var opts = MarkdownRenderer.Options()
        opts.renderTOC = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let noLiteralMarker = try await webView.evaluateJavaScript(
            "document.body.textContent.indexOf('[TOC]') === -1"
        )
        let allLinksResolve = try await webView.evaluateJavaScript("""
        Array.from(document.querySelectorAll('.toc-h1 a, .toc-h2 a, .toc-h3 a, .toc-h4 a, .toc-h5 a, .toc-h6 a'))
            .every(function (a) {
                var id = a.getAttribute('href').slice(1);
                return !!document.getElementById(id);
            });
        """)
        let linkCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.toc-h1 a, .toc-h2 a').length"
        )
        #expect((noLiteralMarker as? Bool) == true)
        #expect((linkCount as? Int) == 2)
        #expect(
            (allLinksResolve as? Bool) == true,
            "Every TOC link must target an id that actually exists on a heading"
        )
    }

    @Test("SmartyPants: straight quotes and punctuation convert to typographic equivalents")
    @MainActor
    func smartyPants() async throws {
        let md = #""quoted" and it's -- like this... done"#
        var opts = MarkdownRenderer.Options()
        opts.smartPunctuation = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let text = try await webView.evaluateJavaScript("document.body.textContent")
        let str = text as? String ?? ""
        #expect(str.contains("\u{201C}quoted\u{201D}"), "Expected curly double quotes")
        #expect(str.contains("\u{2013}") || str.contains("\u{2014}"), "Expected an en/em dash from --")
        #expect(str.contains("\u{2026}"), "Expected an ellipsis character from ...")
    }

    @Test("Alerts (GFM): a [!NOTE] blockquote renders as a titled, classed alert block")
    @MainActor
    func alerts() async throws {
        let md = "> [!NOTE]\n> Useful information."
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let webView = try await renderPreviewWebView(markdown: md, options: opts)
        let hasAlertClass = try await webView.evaluateJavaScript(
            "!!document.querySelector('blockquote.markdown-alert.markdown-alert-note')"
        )
        let titleText = try await webView.evaluateJavaScript(
            "document.querySelector('.markdown-alert-title') ? document.querySelector('.markdown-alert-title')" +
                ".textContent : null"
        )
        let bodyText = try await webView.evaluateJavaScript("document.body.textContent")
        #expect((hasAlertClass as? Bool) == true, "Expected the blockquote to carry markdown-alert-note")
        #expect((titleText as? String) == "Note")
        #expect((bodyText as? String)?.contains("Useful information.") == true)
        #expect((bodyText as? String)?.contains("[!NOTE]") == false, "The literal marker must not remain in the text")
    }

    @Test("Mermaid diagrams: a fenced mermaid block renders as an inline SVG, not plain code")
    @MainActor
    func mermaidDiagrams() async throws {
        let md = "```mermaid\ngraph TD;\nA-->B;\n```"
        let webView = try await renderPreviewWebView(markdown: md) { prefs in
            prefs.htmlMermaid = true
        }
        let rendered = try await pollUntilTrue(webView, js: "!!document.querySelector('svg')", timeout: .seconds(10))
        #expect(rendered, "Expected Mermaid to replace the fenced code block with an inline <svg>")
        let stillPlainCode = try await webView.evaluateJavaScript(
            "!!document.querySelector('code.language-mermaid')"
        )
        #expect(
            (stillPlainCode as? Bool) == false,
            "The raw mermaid source code block should be replaced by the diagram"
        )
    }

    @Test("MathJax: inline $...$ math renders as an SVG-backed mjx-container")
    @MainActor
    func mathJax() async throws {
        let md = "Inline math: $x+y$"
        let webView = try await renderPreviewWebView(markdown: md) { prefs in
            prefs.htmlMathJax = true
            prefs.htmlMathJaxInlineDollar = true
        }
        let rendered = try await pollUntilTrue(
            webView, js: "!!document.querySelector('mjx-container svg')", timeout: .seconds(10)
        )
        #expect(rendered, "Expected MathJax to render $x+y$ as an SVG inside an mjx-container")
    }
}

/// Code-block-specific coverage, split from `GFMFeatureCoverageTests` to keep that
/// suite under swiftlint's type body length limit.
@Suite("Code blocks")
struct CodeBlockCoverageTests {
    @Test("Code blocks: fenced code with a language tag gets highlighted by highlight.js")
    @MainActor
    func codeBlocksWithHighlighting() async throws {
        let md = "```swift\nlet x = 1\n```"
        let webView = try await renderPreviewWebView(markdown: md) { prefs in
            prefs.htmlSyntaxHighlighting = true
        }
        let highlighted = try await pollUntilTrue(webView, js: "!!document.querySelector('code.hljs')")
        #expect(highlighted, "Expected highlight.js to add the 'hljs' class to the code block")
        let hasKeywordSpan = try await webView.evaluateJavaScript(
            "!!document.querySelector('code.hljs .hljs-keyword')"
        )
        #expect((hasKeywordSpan as? Bool) == true, "Expected a tokenized span (e.g. hljs-keyword) inside the block")
    }

    @Test("Code blocks: line numbers don't leave stray newline text nodes between lines")
    @MainActor
    func codeBlocksWithLineNumbers() async throws {
        let md = "```swift\ntell application \"Fen\"\n    beep\nend tell\n```"
        let webView = try await renderPreviewWebView(markdown: md) { prefs in
            prefs.htmlSyntaxHighlighting = true
            prefs.htmlLineNumbers = true
        }
        let rendered = try await pollUntilTrue(webView, js: "!!document.querySelector('code.fen-line-numbers')")
        #expect(rendered, "Expected the highlighted block to get the fen-line-numbers class")
        let lineCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('code.fen-line-numbers .fen-line').length"
        )
        #expect(
            (lineCount as? Int) == 3,
            "Expected exactly 3 .fen-line spans, one per source line, got \(String(describing: lineCount))"
        )

        // A leftover "\n".join() between <span class="fen-line"> elements leaves a raw text
        // node child on <code> itself; inside <pre> (white-space: pre) that renders as a
        // second, empty line between every already-block-level span, doubling the spacing.
        let hasStrayNewlineTextNode = try await webView.evaluateJavaScript("""
        Array.from(document.querySelector('code.fen-line-numbers').childNodes)
            .some(function (node) { return node.nodeType === Node.TEXT_NODE && node.textContent.includes('\\n'); });
        """)
        #expect(
            (hasStrayNewlineTextNode as? Bool) == false,
            "Found a stray newline text node between .fen-line spans, which doubles the visual line spacing"
        )
    }

    @Test("Code blocks: indented (non-fenced) code renders as <pre><code> without a language class")
    @MainActor
    func indentedCodeBlocks() async throws {
        let md = "    plain indented code"
        let webView = try await renderPreviewWebView(markdown: md)
        let isPreCode = try await webView.evaluateJavaScript("""
        (function () {
            var code = document.querySelector('pre > code');
            return !!code && code.textContent.trim() === 'plain indented code';
        })();
        """)
        #expect((isPreCode as? Bool) == true)
    }
}
