import Foundation

/// `[[name]]`, `[[name|text]]` and `[[name#heading]]` links (issue #36). Not a cmark-gfm syntax,
/// so this is a pass over the rendered HTML, like `applyEmojiShortcodes`. A found document becomes
/// a normal relative link, which the preview already opens as an internal link. A name with no
/// document gets a muted span. Without a resolver (the file is in no workspace) the text stays as written.
extension MarkdownRenderer {
    private static let wikiLinkPattern =
        #"<pre[^>]*>.*?</pre>|<code[^>]*>.*?</code>|<a\b[^>]*>.*?</a>|<[^>]*>|\[\[([^\[\]\n]+)\]\]"#

    func applyWikiLinks(to html: String, resolver: WikiLinkResolver) -> String {
        guard html.contains("[["),
              let regex = try? NSRegularExpression(pattern: Self.wikiLinkPattern, options: [.dotMatchesLineSeparators])
        else {
            return html
        }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var result = ""
        var cursor = 0
        for match in matches {
            result += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let inner = match.range(at: 1)
            if inner.location != NSNotFound,
               let link = wikiLinkHTML(for: nsHTML.substring(with: inner), resolver: resolver) {
                result += link
            } else {
                result += nsHTML.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += nsHTML.substring(with: NSRange(location: cursor, length: nsHTML.length - cursor))
        return result
    }

    /// `inner` is the text between the brackets, still HTML-escaped as cmark wrote it.
    private func wikiLinkHTML(for inner: String, resolver: WikiLinkResolver) -> String? {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = String(parts[0])
        let name = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let plainName = Self.unescapeHTML(String(name))
        guard !plainName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let text = parts.count > 1 ? String(parts[1]) : target
        guard let path = resolver.resolve(plainName) else {
            let title = Self.escapeHTML("No document named \(plainName.trimmingCharacters(in: .whitespaces))")
            return "<span class=\"wikilink wikilink-unresolved\" title=\"\(title)\">\(text)</span>"
        }
        return "<a class=\"wikilink\" href=\"\(Self.percentEncode(path))\">\(text)</a>"
    }

    private static let entities = [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;")]

    private static func unescapeHTML(_ text: String) -> String {
        entities.reversed().reduce(text) { $0.replacingOccurrences(of: $1.1, with: $1.0) }
    }

    private static func escapeHTML(_ text: String) -> String {
        entities.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static func percentEncode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map {
                $0
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed
                        .subtracting(CharacterSet(charactersIn: "/?#&"))) ?? String($0)
            }
            .joined(separator: "/")
    }
}
