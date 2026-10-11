@testable import FenCore
import Foundation
import Testing
import WebKit

@Suite("Wiki links (issue #36)")
struct WikiLinkTests {
    private let paths = [
        "index.md", "notes/Budget Plan.md", "notes/ideas.md", "archive/ideas.md", "docs/guide/setup.md",
        "docs/Ship.markdown",
    ]

    private func resolver(from current: String) -> WikiLinkResolver {
        WikiLinkResolver(paths: paths, current: current)
    }

    private func render(
        _ markdown: String,
        from current: String = "index.md",
        resolver: WikiLinkResolver? = nil
    ) -> String {
        var options = MarkdownRenderer.Options()
        options.wikiLinks = resolver ?? self.resolver(from: current)
        return MarkdownRenderer().render(markdown, options: options).html
    }

    // MARK: - Resolver

    @Test("a name matches a file name or a whole path, ignoring case and extension")
    func matching() {
        let resolver = resolver(from: "index.md")
        #expect(resolver.resolve("budget plan") == "notes/Budget%20Plan.md".removingPercentEncoding)
        #expect(resolver.resolve("DOCS/ship") == "docs/Ship.markdown")
        #expect(resolver.resolve("Ship.markdown") == "docs/Ship.markdown")
        #expect(resolver.resolve("notes/budget plan.md") == "notes/Budget Plan.md")
        #expect(resolver.resolve("missing") == nil)
        #expect(resolver.resolve("   ") == nil)
    }

    @Test("the link is relative to the open document")
    func relative() {
        #expect(resolver(from: "docs/guide/setup.md").resolve("ship") == "../Ship.markdown")
        #expect(resolver(from: "docs/guide/setup.md").resolve("index") == "../../index.md")
        #expect(resolver(from: "notes/ideas.md").resolve("budget plan") == "Budget Plan.md")
    }

    @Test("a name shared by two files picks the nearest one, the same way every time")
    func nearest() {
        #expect(resolver(from: "notes/budget plan.md").resolve("ideas") == "ideas.md")
        #expect(resolver(from: "archive/old.md").resolve("ideas") == "ideas.md")
        // Same distance from the root: the shorter path wins, then the first alphabetically.
        let tie = WikiLinkResolver(paths: ["b/x.md", "a/x.md", "index.md"], current: "index.md")
        #expect(tie.resolve("x") == "a/x.md")
    }

    @Test("the resolver only knows its own workspace's files")
    func otherWorkspace() {
        let mine = WikiLinkResolver(paths: ["index.md"], current: "index.md")
        let theirs = WikiLinkResolver(paths: ["secret.md"], current: "index.md")
        #expect(mine.resolve("secret") == nil)
        #expect(theirs.resolve("secret") == "secret.md")
    }

    // MARK: - Rendering

    @Test("a found name becomes a relative link, with an alias and a heading accepted")
    func renderLinks() {
        let html = render("See [[ideas]], [[Ideas|my ideas]] and [[budget plan#Totals]].", from: "notes/x.md")
        #expect(html.contains(#"<a class="wikilink" href="ideas.md">ideas</a>"#))
        #expect(html.contains(#"<a class="wikilink" href="ideas.md">my ideas</a>"#))
        #expect(html.contains(#"<a class="wikilink" href="Budget%20Plan.md">budget plan#Totals</a>"#))
    }

    @Test("a name with no document becomes a muted span that says so")
    func renderUnresolved() {
        let html = render(#"A [[ghost "town"]] here."#)
        #expect(html.contains(#"class="wikilink wikilink-unresolved""#))
        #expect(html.contains("No document named ghost &quot;town&quot;"))
        #expect(!html.contains("<a class=\"wikilink\""))
    }

    @Test("code, existing links and tags are left alone")
    func skipped() {
        let html = render("""
        `[[ideas]]`

        ```
        [[ideas]]
        ```

        [see [[ideas]]](https://example.com)

        <span title="[[ideas]]">x</span>
        """)
        #expect(!html.contains("class=\"wikilink\""))
        #expect(html.contains("<code>[[ideas]]</code>"))
        #expect(html.contains(#"title="[[ideas]]""#))
    }

    @Test("escaped characters in a name still match, and the output stays escaped")
    func escaping() {
        let resolver = WikiLinkResolver(paths: ["Q&A.md", "a<b.md"], current: "index.md")
        let html = render("[[Q&A]] and [[a<b]]", resolver: resolver)
        #expect(html.contains(#"href="Q%26A.md">Q&amp;A</a>"#))
        #expect(html.contains(#"href="a%3Cb.md">a&lt;b</a>"#))
    }

    @Test("without a resolver the text stays as written")
    func noResolver() {
        let html = MarkdownRenderer().render("[[ideas]]").html
        #expect(html.contains("[[ideas]]"))
        #expect(!html.contains("wikilink"))
    }

    // MARK: - On screen

    @Test("in a real WebView the link has a box, opens as an internal link, and a missing name looks muted")
    @MainActor
    func inWebView() async throws {
        let folder = try TempFolder("wikilink-web")
        defer { folder.cleanUp() }
        _ = try folder.write("notes/ideas.md", "# Ideas\n")
        _ = try folder.write("notes/Budget Plan.md", "# Budget\n")
        var options = MarkdownRenderer.Options()
        options.wikiLinks = WikiLinkResolver(
            paths: ["index.md", "notes/ideas.md", "notes/Budget Plan.md"],
            current: "index.md"
        )
        let webView = try await renderPreviewWebView(
            markdown: "Read [[ideas|my ideas]], [[budget plan]] or [[ghost]].", options: options,
            baseDirectory: folder.root
        )

        let box = try await webView.evaluateJavaScript(
            "(function(){var r=document.querySelector('a.wikilink').getBoundingClientRect();return r.width>0&&r.height>0;})()"
        )
        #expect((box as? Bool) == true)
        let muted = try await webView.evaluateJavaScript(
            "(function(){var s=getComputedStyle(document.querySelector('span.wikilink-unresolved'));"
                + "return s.borderBottomStyle+'|'+s.opacity;})()"
        )
        #expect((muted as? String) == "dotted|0.6")
        let href = try #require(await webView
            .evaluateJavaScript("document.querySelector('a.wikilink').href") as? String)

        let handler = PreviewSchemeHandler()
        handler.baseDirectory = folder.root
        let url = try #require(URL(string: href))
        let target = try #require(handler.internalLinkTarget(for: url))
        #expect(target.standardizedFileURL.path.hasSuffix("/notes/ideas.md"))

        // A name with a space is percent-encoded in the href and still opens the right file.
        let spaced = try #require(await webView
            .evaluateJavaScript("document.querySelectorAll('a.wikilink')[1].href") as? String)
        let spacedURL = try #require(URL(string: spaced))
        let spacedTarget = try #require(handler.internalLinkTarget(for: spacedURL))
        #expect(spacedTarget.standardizedFileURL.path.hasSuffix("/notes/Budget Plan.md"))
    }
}
