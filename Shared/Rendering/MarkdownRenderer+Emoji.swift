import Foundation

/// Emoji shortcode extension (`:rocket:` -> unicode emoji, issue #119). Not a cmark-gfm syntax
/// extension (none exists there), so -- following the exact precedent `applyHighlightMarkup`
/// established -- this is applied as a post-processing pass over the already-rendered HTML.
/// Split from `MarkdownRenderer.swift` to keep that file under swiftlint's file/type length
/// limits, mirroring the `+Alerts.swift`/`+TOC.swift` split.
extension MarkdownRenderer {
    /// Shortcode -> unicode emoji character, generated from `github/gemoji`'s MIT-licensed
    /// `db/emoji.json` (see `Shared/Resources/Emoji/LICENSE-gemoji`). Only the ~1,913 aliases
    /// with a Unicode codepoint are included -- GitHub's ~23 non-Unicode custom branding images
    /// (`:octocat:`, `:shipit:`, etc., actual PNGs hosted at github.githubassets.com) are out of
    /// scope, see issue #119's Phase 1 spec.
    static let emojiShortcodes: [String: String] = {
        guard let url = coreBundle.url(forResource: "emoji-shortcodes", withExtension: "json", subdirectory: "Emoji"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return table
    }()

    /// Every alias in `emojiShortcodes` is `[A-Za-z0-9_+-]+` (confirmed against the source data),
    /// so this character class is safe without further escaping.
    private static let emojiPattern = #"<pre[^>]*>.*?</pre>|<code[^>]*>.*?</code>|<[^>]*>|:([A-Za-z0-9_+-]+):"#

    /// Replaces every `:shortcode:` span with its looked-up unicode emoji character, skipping any
    /// span inside a `<pre>`/`<code>` block or inside any HTML tag itself -- the same
    /// tag/code-skipping technique `applyHighlightMarkup` uses, so a literal `:shortcode:`-looking
    /// string inside code, or inside tag markup, is left untouched. An unrecognized shortcode
    /// (no match in the table) is left as literal text rather than removed.
    func applyEmojiShortcodes(to html: String) -> String {
        guard !Self.emojiShortcodes.isEmpty,
              let regex = try? NSRegularExpression(pattern: Self.emojiPattern, options: [.dotMatchesLineSeparators])
        else {
            return html
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for match in matches {
            result += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let shortcodeRange = match.range(at: 1)
            if shortcodeRange.location != NSNotFound,
               let emoji = Self.emojiShortcodes[nsHTML.substring(with: shortcodeRange)] {
                result += emoji
            } else {
                result += nsHTML.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += nsHTML.substring(with: NSRange(location: cursor, length: nsHTML.length - cursor))
        return result
    }
}
