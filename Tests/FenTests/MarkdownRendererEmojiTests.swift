@testable import FenCore
import Testing

/// Emoji shortcode extension (issue #119) coverage, split from `MarkdownRendererTests` to keep
/// that suite under swiftlint's file/type length limits -- mirrors the `MarkdownRendererAlertsTests`
/// split.
@Suite("MarkdownRenderer Emoji Tests")
struct MarkdownRendererEmojiTests {
    let renderer = MarkdownRenderer()

    @Test(
        "Common shortcodes render as their unicode emoji when enabled",
        arguments: [
            ("rocket", "🚀"),
            ("tada", "🎉"),
            ("smile", "😄"),
            ("+1", "👍"),
            ("octocat", nil as String?),
        ]
    )
    func shortcodesRenderExpectedEmoji(alias: String, expected: String?) {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render("Hello :\(alias):", options: opts)
        if let expected {
            #expect(result.html.contains(expected))
            #expect(!result.html.contains(":\(alias):"))
        } else {
            // github/gemoji has no Unicode entry for GitHub's custom branding images
            // (:octocat:, :shipit:, etc.) -- see issue #119's Phase 1 spec. Left as literal text.
            #expect(result.html.contains(":\(alias):"))
        }
    }

    @Test("Disabled emojiShortcodes option leaves shortcode text untouched")
    func disabledOptionLeavesTextLiteral() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = false
        let result = renderer.render("Hello :rocket:", options: opts)
        #expect(result.html.contains(":rocket:"))
        #expect(!result.html.contains("🚀"))
    }

    @Test("A shortcode inside a fenced code block is left literal")
    func shortcodeInsideFencedCodeBlockIsLiteral() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render("```\nliteral :rocket: text\n```", options: opts)
        #expect(result.html.contains(":rocket:"))
        #expect(!result.html.contains("🚀"))
    }

    @Test("A shortcode inside an inline code span is left literal")
    func shortcodeInsideInlineCodeSpanIsLiteral() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render("Use `:rocket:` literally.", options: opts)
        #expect(result.html.contains(":rocket:"))
        #expect(!result.html.contains("🚀"))
    }

    @Test("An unrecognized shortcode is left as literal text")
    func unrecognizedShortcodeIsLiteral() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render("Hello :not_a_real_shortcode_xyz:", options: opts)
        #expect(result.html.contains(":not_a_real_shortcode_xyz:"))
    }

    @Test("A shortcode-looking sequence inside a tag's attribute is left untouched")
    func shortcodeInsideTagAttributeIsUntouched() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        // A link whose title contains a colon-delimited, non-emoji token must not be corrupted
        // by the regex matching across the tag boundary: the whole `<a ...>` tag (attributes
        // included) matches the tag-skipping alternative first, so its contents are never
        // considered for shortcode substitution.
        let result = renderer.render("[link](https://fen.md \":rocket:\")", options: opts)
        #expect(result.html.contains("title=\":rocket:\""))
        #expect(!result.html.contains("title=\"🚀\""))
    }

    @Test("The bundled shortcode table loads and is non-empty")
    func shortcodeTableLoads() {
        #expect(!MarkdownRenderer.emojiShortcodes.isEmpty)
        #expect(MarkdownRenderer.emojiShortcodes.count > 1800)
        #expect(MarkdownRenderer.emojiShortcodes["rocket"] == "🚀")
    }
}
