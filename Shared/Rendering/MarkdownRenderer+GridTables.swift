import Foundation

/// Pandoc grid tables (`+----+----+` borders, `|` cells) aren't GFM, and neither is GitHub
/// rendering them (issue #258). cmark-gfm folds one into a single paragraph, so the preview
/// shows a wall of `+` and `-` with no hint why. This pass swaps that paragraph for a notice
/// and keeps the original text below it. It does not render the table.
extension MarkdownRenderer {
    static let gridTableNotice = "This is a pandoc grid table. Fen renders GFM pipe tables only."

    /// A paragraph whose first line is a grid border (`+---+===+` and so on) and whose second
    /// line starts a cell row. Code blocks render as `<pre>`, never `<p>`, so fenced or
    /// indented grid tables in code are left alone. `+ item` is a list marker, not a border,
    /// because a border has no space after the `+`.
    private static let gridTablePattern = #"<p((?: [^>]*)?)>(\+[-=:+]+\+\n\|[\s\S]*?)</p>"#

    /// Keeps the paragraph's `data-sourcepos` on the wrapper so scroll sync still finds the block.
    func applyGridTableNotice(to html: String, enabled: Bool) -> String {
        guard enabled, html.contains("<p"),
              let regex = try? NSRegularExpression(pattern: Self.gridTablePattern) else { return html }
        let template = #"<div class="fen-notice"$1><p class="fen-notice-title">"#
            + Self.gridTableNotice
            + #"</p><pre>$2</pre></div>"#
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: (html as NSString).length),
            withTemplate: template
        )
    }
}
