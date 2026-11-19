import Foundation

/// Pandoc grid tables (`+----+----+` borders, `|` cells) aren't GFM, and neither is GitHub
/// rendering them (issue #258). cmark-gfm folds one into a single paragraph, so the preview
/// shows a wall of `+` and `-` with no hint why. This pass swaps that paragraph for a notice
/// and keeps the paragraph's text below it. It does not render the table.
extension MarkdownRenderer {
    static let gridTableNotice = "This is a pandoc grid table. Fen renders GFM pipe tables only."

    /// A paragraph whose first line is a grid border (`+---+===+` and so on) and whose second
    /// line starts a cell row. Code blocks render as `<pre>`, never `<p>`, so fenced or
    /// indented grid tables in code are left alone. `+ item` is a list marker, not a border,
    /// because a border has no space after the `+`.
    ///
    /// The border class also takes en and em dashes, because smart punctuation turns `--` and
    /// `---` into them. The line break may be `<br />\n` when hard wrap is on.
    ///
    /// Not matched: a table inside a tight list item (cmark emits no `<p>` there), and a table
    /// that follows a text line with no blank line between (the paragraph starts with the text).
    private static let gridTablePattern =
        #"<p((?: [^>]*)?)>(\+[-=:+\u2013\u2014]+\+(?:<br />)?\n\|[\s\S]*?)</p>"#

    /// Keeps the paragraph's `data-sourcepos` on the wrapper so scroll sync still finds the block.
    func applyGridTableNotice(to html: String, enabled: Bool) -> String {
        guard enabled, html.contains("<p"),
              let regex = try? NSRegularExpression(pattern: Self.gridTablePattern) else { return html }
        let nsHTML = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            result += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let attributes = nsHTML.substring(with: match.range(at: 1))
            // Hard wrap renders each line break as `<br />\n`. Inside `<pre>` that doubles the lines.
            let text = nsHTML.substring(with: match.range(at: 2)).replacingOccurrences(of: "<br />\n", with: "\n")
            result += #"<div class="fen-notice"\#(attributes)><p class="fen-notice-title">\#(Self.gridTableNotice)"#
                + "</p><pre>\(text)</pre></div>"
            cursor = match.range.location + match.range.length
        }
        return result + nsHTML.substring(from: cursor)
    }
}
