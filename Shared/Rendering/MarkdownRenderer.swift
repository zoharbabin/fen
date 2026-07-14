import cmark_gfm
import cmark_gfm_extensions
import Foundation
import Yams

/// Renders Markdown text to HTML using cmark-gfm.
public struct MarkdownRenderer: Sendable {
    public struct Options: Sendable {
        public var tables: Bool = true
        public var strikethrough: Bool = true
        public var autolink: Bool = true
        public var taskList: Bool = true
        public var tagfilter: Bool = false
        public var hardBreaks: Bool = false
        public var smartPunctuation: Bool = false
        public var footnotes: Bool = true
        /// `==text==` -> `<mark>text</mark>`. Not a cmark-gfm extension (no such syntax
        /// extension exists there), so this is applied as a post-processing pass over the
        /// rendered HTML rather than a parser option -- see `applyHighlightMarkup`.
        public var highlight: Bool = false
        public var renderTOC: Bool = false
        public var detectFrontMatter: Bool = true
        /// Emits `data-sourcepos="startLine:col-endLine:col"` on block elements, which
        /// `Shared/Resources/ScrollSync/scroll-sync.js` uses to correct for uneven density
        /// between the source Markdown and the rendered HTML. Off by default since it's
        /// only useful to the live preview, not export.
        public var sourcePositions: Bool = false

        public init() {}

        public static func from(preferences: Preferences) -> Options {
            var opts = Options()
            opts.tables = preferences.extensionTables
            opts.strikethrough = preferences.extensionStrikethrough
            opts.autolink = preferences.extensionAutolink
            opts.taskList = preferences.htmlTaskList
            opts.hardBreaks = preferences.htmlHardWrap
            opts.smartPunctuation = preferences.extensionSmartyPants
            opts.renderTOC = preferences.htmlRendersTOC
            opts.detectFrontMatter = preferences.htmlDetectFrontMatter
            opts.footnotes = preferences.extensionFootnotes
            opts.highlight = preferences.extensionHighlight
            return opts
        }
    }

    public struct RenderResult: @unchecked Sendable {
        public let html: String
        public let frontMatter: [String: Any]?
        public let title: String?
        /// Number of lines stripped from the front of the source before parsing (0 if there was
        /// no front matter). cmark-gfm's `data-sourcepos` line numbers are relative to the
        /// stripped text, so scroll-sync must add this back to recover the raw-source line number.
        public let frontMatterLineCount: Int
        /// Every heading in document order, independent of `Options.renderTOC` -- consumers
        /// like the document outline navigator (issue #12) need this list even when `[TOC]`
        /// rendering is off. `startLine` is only populated when `Options.sourcePositions` is on
        /// (it's read off the same `data-sourcepos` attribute scroll-sync already relies on).
        public let headings: [Heading]

        /// frontMatter is [String: Any] which isn't Sendable, but we only
        /// produce it from controlled YAML parsing. Mark as safe.
        static let empty = RenderResult(html: "", frontMatter: nil, title: nil, frontMatterLineCount: 0, headings: [])
    }

    /// One Markdown heading, extracted from the rendered `<h1>`-`<h6>` tags. Shared by both
    /// `[TOC]` HTML generation and the document outline navigator (issue #12) so there's one
    /// heading-extraction implementation, not two.
    public struct Heading: Sendable, Equatable {
        public let level: Int
        public let text: String
        public let slug: String
        /// 1-based source line the heading starts on, or `nil` if `Options.sourcePositions`
        /// was off for this render.
        public let startLine: Int?

        public init(level: Int, text: String, slug: String, startLine: Int? = nil) {
            self.level = level
            self.text = text
            self.slug = slug
            self.startLine = startLine
        }
    }

    public init() {
        // Register GFM extensions once
        cmark_gfm_core_extensions_ensure_registered()
    }

    /// Render markdown text to HTML with the given options.
    public func render(_ markdown: String, options: Options = Options()) -> RenderResult {
        var text = markdown
        var frontMatter: [String: Any]?
        var title: String?
        var frontMatterLineCount = 0

        // Extract YAML front matter
        if options.detectFrontMatter {
            let extracted = extractFrontMatter(from: text)
            text = extracted.stripped
            frontMatter = extracted.yaml
            title = extracted.yaml?["title"] as? String
            frontMatterLineCount = extracted.lineCount
        }

        // Parse markdown to AST
        let cmarkOptions: Int32 = (options.footnotes ? CMARK_OPT_FOOTNOTES : 0)
            | (options.hardBreaks ? CMARK_OPT_HARDBREAKS : 0)
            | (options.smartPunctuation ? CMARK_OPT_SMART : 0)
            | (options.sourcePositions ? CMARK_OPT_SOURCEPOS : 0)

        guard let parser = cmark_parser_new(cmarkOptions) else {
            return .empty
        }
        defer { cmark_parser_free(parser) }

        attachSyntaxExtensions(to: parser, options: options)

        // Feed text to parser
        cmark_parser_feed(parser, text, text.utf8.count)
        guard let doc = cmark_parser_finish(parser) else {
            return .empty
        }
        defer { cmark_node_free(doc) }

        // Render to HTML
        guard let htmlPtr = cmark_render_html(doc, cmarkOptions, cmark_parser_get_syntax_extensions(parser)) else {
            return .empty
        }
        var html = String(cString: htmlPtr)
        free(htmlPtr)

        if options.highlight {
            html = applyHighlightMarkup(to: html)
        }

        // Heading extraction always runs so RenderResult.headings is populated regardless of
        // renderTOC (the document outline navigator, issue #12, needs it even with [TOC] off);
        // only the HTML itself is rewritten with ids/TOC markup when renderTOC is on, to keep
        // that output unchanged for consumers who never opt into it.
        let extracted = extractHeadingsAndAssignIDs(from: html)
        if options.renderTOC {
            html = extracted.html
            html = replaceTOCMarker(in: html, with: extracted.toc)
        }

        return RenderResult(
            html: html,
            frontMatter: frontMatter,
            title: title,
            frontMatterLineCount: frontMatterLineCount,
            headings: extracted.headings
        )
    }

    /// Attaches each enabled GFM syntax extension (table/strikethrough/autolink/tasklist/
    /// tagfilter) to `parser`.
    private func attachSyntaxExtensions(to parser: UnsafeMutablePointer<cmark_parser>, options: Options) {
        if options.tables, let ext = cmark_find_syntax_extension("table") {
            cmark_parser_attach_syntax_extension(parser, ext)
        }
        if options.strikethrough, let ext = cmark_find_syntax_extension("strikethrough") {
            cmark_parser_attach_syntax_extension(parser, ext)
        }
        if options.autolink, let ext = cmark_find_syntax_extension("autolink") {
            cmark_parser_attach_syntax_extension(parser, ext)
        }
        if options.taskList, let ext = cmark_find_syntax_extension("tasklist") {
            cmark_parser_attach_syntax_extension(parser, ext)
        }
        if options.tagfilter, let ext = cmark_find_syntax_extension("tagfilter") {
            cmark_parser_attach_syntax_extension(parser, ext)
        }
    }

    // MARK: - Front Matter

    private struct FrontMatterResult {
        let stripped: String
        let yaml: [String: Any]?
        let lineCount: Int
    }

    private func extractFrontMatter(from text: String) -> FrontMatterResult {
        guard text.hasPrefix("---") else { return FrontMatterResult(stripped: text, yaml: nil, lineCount: 0) }

        let lines = text.components(separatedBy: "\n")
        guard lines.count > 2 else { return FrontMatterResult(stripped: text, yaml: nil, lineCount: 0) }

        var endIndex: Int?
        for i in 1 ..< lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            endIndex = i
            break
        }

        guard let end = endIndex else { return FrontMatterResult(stripped: text, yaml: nil, lineCount: 0) }

        let yamlContent = lines[1 ..< end].joined(separator: "\n")
        let remaining = lines[(end + 1)...].joined(separator: "\n")

        let yaml = try? Yams.load(yaml: yamlContent) as? [String: Any]
        return FrontMatterResult(stripped: remaining, yaml: yaml, lineCount: end + 1)
    }

    // MARK: - Highlight Extension (==text== -> <mark>, issue #52)

    /// Wraps `==text==` spans in `<mark>`, skipping any span inside a `<pre>`/`<code>` block or
    /// inside any HTML tag itself (e.g. a `==` pair inside a link's `href` query string) --
    /// cmark has already rendered code spans/fences and tags to HTML by this point, so scanning
    /// for them (rather than the original Markdown backticks/fences) is what keeps literal
    /// `==...==` inside code, or inside tag markup, untouched.
    private func applyHighlightMarkup(to html: String) -> String {
        let pattern = #"<pre[^>]*>.*?</pre>|<code[^>]*>.*?</code>|<[^>]*>|==([^=\n]+?)=="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return html
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for match in matches {
            result += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let highlightRange = match.range(at: 1)
            if highlightRange.location != NSNotFound {
                result += "<mark>\(nsHTML.substring(with: highlightRange))</mark>"
            } else {
                result += nsHTML.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += nsHTML.substring(with: NSRange(location: cursor, length: nsHTML.length - cursor))
        return result
    }

    // MARK: - Heading Extraction & TOC Generation

    /// Walks every `<h1>`-`<h6>` tag once, assigning each a unique `id` (deduping repeated
    /// slugs the way GitHub does, with `-1`, `-2`, ... suffixes), building a `[TOC]`-ready
    /// HTML list, and collecting the same data as `Heading` values -- the single source both
    /// `[TOC]` rendering and the document outline navigator (issue #12) read from.
    private func extractHeadingsAndAssignIDs(
        from html: String
    ) -> (html: String, toc: String, headings: [Heading]) {
        // Captures any existing attributes (e.g. data-sourcepos) separately from the
        // content, so they survive being spliced back into the rewritten opening tag.
        let pattern = #"<h([1-6])([^>]*)>(.*?)</h\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return (html, "", [])
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return (html, "", []) }

        var usedSlugs: [String: Int] = [:]
        var toc = "<ul>\n"
        var updatedHTML = ""
        var cursor = 0
        var headings: [Heading] = []

        for match in matches {
            updatedHTML += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))

            let level = nsHTML.substring(with: match.range(at: 1))
            let attributes = nsHTML.substring(with: match.range(at: 2))
            let content = nsHTML.substring(with: match.range(at: 3))
            let plainText = content.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            let slug = uniqueSlug(for: plainText, usedSlugs: &usedSlugs)

            updatedHTML += "<h\(level) id=\"\(slug)\"\(attributes)>\(content)</h\(level)>"
            toc += "<li class=\"toc-h\(level)\"><a href=\"#\(slug)\">\(plainText)</a></li>\n"
            headings.append(Heading(
                level: Int(level) ?? 1,
                text: plainText,
                slug: slug,
                startLine: startLine(fromDataSourcepos: attributes)
            ))

            cursor = match.range.location + match.range.length
        }
        updatedHTML += nsHTML.substring(with: NSRange(location: cursor, length: nsHTML.length - cursor))
        toc += "</ul>"

        return (updatedHTML, toc, headings)
    }

    /// Parses the 1-based start line out of a `data-sourcepos="startLine:col-endLine:col"`
    /// attribute, or `nil` if the tag has no such attribute (sourcePositions was off).
    private func startLine(fromDataSourcepos attributes: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"data-sourcepos="(\d+):"#) else { return nil }
        let nsAttributes = attributes as NSString
        guard let match = regex.firstMatch(
            in: attributes,
            range: NSRange(location: 0, length: nsAttributes.length)
        ) else { return nil }
        return Int(nsAttributes.substring(with: match.range(at: 1)))
    }

    private func uniqueSlug(for text: String, usedSlugs: inout [String: Int]) -> String {
        let base = text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)

        guard let count = usedSlugs[base] else {
            usedSlugs[base] = 0
            return base
        }
        let next = count + 1
        usedSlugs[base] = next
        return "\(base)-\(next)"
    }

    private func replaceTOCMarker(in html: String, with toc: String) -> String {
        let pattern = #"<p[^>]*>\s*\[TOC\]\s*</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: (html as NSString).length),
            withTemplate: toc
        )
    }
}
