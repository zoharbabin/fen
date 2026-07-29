import Foundation

/// Heading extraction & `[TOC]` generation (issues #12/#21). Split from
/// `MarkdownRenderer.swift` to keep that file under swiftlint's file/type length limits.
extension MarkdownRenderer {
    /// Walks every `<h1>`-`<h6>` tag once, assigning each a unique `id` (deduping repeated
    /// slugs the way GitHub does, with `-1`, `-2`, ... suffixes), building a `[TOC]`-ready
    /// HTML list, and collecting the same data as `Heading` values -- the single source both
    /// `[TOC]` rendering and the document outline navigator (issue #12) read from.
    func extractHeadingsAndAssignIDs(
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
            headings.append(Heading(
                level: Int(level) ?? 1,
                text: plainText,
                slug: slug,
                startLine: startLine(fromDataSourcepos: attributes)
            ))

            cursor = match.range.location + match.range.length
        }
        updatedHTML += nsHTML.substring(with: NSRange(location: cursor, length: nsHTML.length - cursor))

        return (updatedHTML, nestedTOCHTML(for: headings), headings)
    }

    /// Builds the `[TOC]` marker's replacement HTML as `<ul>`s nested by heading level, mirroring
    /// the hierarchy `DocumentOutlineSidebar` shows. The prior approach emitted a single flat
    /// `<ul>` of sibling `<li>`s carrying only a `toc-hN` class as a depth hint, which rendered
    /// with no visible structure since no theme styles that class.
    ///
    /// `<ul>`/`<li>` get inline `margin: 0; padding: 0` (only `<ul>` keeps a left indent) rather
    /// than relying on a theme's list CSS: every theme sets a per-`<li>` margin for ordinary
    /// Markdown lists, and margins between a nested `<ul>`'s last item and its parent `<li>`'s
    /// boundary collapse differently than a plain sibling-to-sibling margin, visibly widening the
    /// gap around any `<li>` that has a nested child. Zeroing both margin and padding leaves
    /// line-height alone as the only spacing, which is uniform regardless of nesting.
    private func nestedTOCHTML(for headings: [Heading]) -> String {
        guard !headings.isEmpty else { return "" }

        let ulStyle = #" style="margin: 0; padding: 0 0 0 1.2em;""#
        let liStyle = #" style="margin: 0; padding: 0;""#

        var toc = ""
        var openLevels: [Int] = []

        for heading in headings {
            while let deepest = openLevels.last, heading.level < deepest {
                toc += "</li></ul>\n"
                openLevels.removeLast()
            }
            if let deepest = openLevels.last, heading.level == deepest {
                toc += "</li>\n"
            } else {
                toc += "<ul\(ulStyle)>\n"
                openLevels.append(heading.level)
            }
            toc += "<li class=\"toc-h\(heading.level)\"\(liStyle)><a href=\"#\(heading.slug)\">\(heading.text)</a>"
        }
        toc += String(repeating: "</li></ul>\n", count: openLevels.count)

        return toc
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

    func replaceTOCMarker(in html: String, with toc: String) -> String {
        // Captures the replaced `<p>`'s own attributes (including `data-sourcepos`)
        // separately from its content, so they can be spliced onto the generated list --
        // mirroring extractHeadingsAndAssignIDs's approach for `<hN>` tags above.
        let pattern = #"<p([^>]*)>\s*\[TOC\]\s*</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for match in matches {
            result += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let attributes = nsHTML.substring(with: match.range(at: 1))
            result += tocHTML(toc, withAttributes: attributes)
            cursor = match.range.location + match.range.length
        }
        result += nsHTML.substring(with: NSRange(location: cursor, length: nsHTML.length - cursor))
        return result
    }

    /// Splices the replaced `[TOC]` marker's own attributes (chiefly `data-sourcepos`) onto
    /// `toc`'s outermost `<ul>`. Without this, the generated list -- which can span dozens of
    /// rendered lines for a document with many headings -- carries no `data-sourcepos` of its
    /// own anywhere in its subtree, so scroll-sync's/the gutter's "one number per leaf block"
    /// rule (rule 3.3) has nothing to anchor to across that entire span: every block before the
    /// marker and every block after it gets numbered, but the marker's own block, and the visual
    /// space it occupies, silently has none. Splicing the attribute onto the outer `<ul>` (whose
    /// `<li>`s/nested `<ul>`s never carry `data-sourcepos` themselves) makes it a leaf, giving the
    /// whole TOC block exactly one gutter number, at its own starting source line.
    private func tocHTML(_ toc: String, withAttributes attributes: String) -> String {
        guard !attributes.isEmpty, let firstULRange = toc.range(of: "<ul") else { return toc }
        return toc.replacingCharacters(in: firstULRange, with: "<ul\(attributes)")
    }
}
