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

        /// frontMatter is [String: Any] which isn't Sendable, but we only
        /// produce it from controlled YAML parsing. Mark as safe.
        static let empty = RenderResult(html: "", frontMatter: nil, title: nil, frontMatterLineCount: 0)
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
        let cmarkOptions: Int32 = CMARK_OPT_FOOTNOTES
            | (options.hardBreaks ? CMARK_OPT_HARDBREAKS : 0)
            | (options.smartPunctuation ? CMARK_OPT_SMART : 0)
            | (options.sourcePositions ? CMARK_OPT_SOURCEPOS : 0)

        guard let parser = cmark_parser_new(cmarkOptions) else {
            return .empty
        }
        defer { cmark_parser_free(parser) }

        // Attach GFM extensions
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

        // TOC replacement
        if options.renderTOC {
            let (headingsWithIDs, toc) = addHeadingIDsAndGenerateTOC(from: html)
            html = headingsWithIDs
            html = replaceTOCMarker(in: html, with: toc)
        }

        return RenderResult(
            html: html, frontMatter: frontMatter, title: title, frontMatterLineCount: frontMatterLineCount
        )
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

    // MARK: - TOC Generation

    /// Assigns a unique `id` to every heading (deduping repeated slugs the way GitHub
    /// does, with `-1`, `-2`, ... suffixes) and builds a TOC whose links target those
    /// same ids, so `[TOC]` entries actually jump to their heading.
    private func addHeadingIDsAndGenerateTOC(from html: String) -> (html: String, toc: String) {
        // Captures any existing attributes (e.g. data-sourcepos) separately from the
        // content, so they survive being spliced back into the rewritten opening tag.
        let pattern = #"<h([1-6])([^>]*)>(.*?)</h\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return (html, "")
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return (html, "") }

        var usedSlugs: [String: Int] = [:]
        var toc = "<ul>\n"
        var updatedHTML = ""
        var cursor = 0

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

            cursor = match.range.location + match.range.length
        }
        updatedHTML += nsHTML.substring(with: NSRange(location: cursor, length: nsHTML.length - cursor))
        toc += "</ul>"

        return (updatedHTML, toc)
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
