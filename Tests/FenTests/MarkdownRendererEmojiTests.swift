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

    @Test("A MAC address is left untouched despite containing hex-valued shortcode aliases")
    func macAddressIsUntouched() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render("Device MAC: a0:08:f3:e5:fa:d9", options: opts)
        #expect(result.html.contains("a0:08:f3:e5:fa:d9"))
    }

    @Test("A MAC address containing :ab: and :de: bytes is left untouched")
    func macAddressWithHexAliasBytesIsUntouched() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render("MAC: 3c:0b:59:de:37:25 and 20:43:ab:d3:b8:11", options: opts)
        #expect(result.html.contains("3c:0b:59:de:37:25"))
        #expect(result.html.contains("20:43:ab:d3:b8:11"))
        #expect(!result.html.contains("🇩🇪"))
        #expect(!result.html.contains("🆎"))
    }

    @Test("An IPv6 address is left untouched")
    func ipv6AddressIsUntouched() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render("Host: 2001:0db8:0000:0000:0000:ff00:0042:8329", options: opts)
        #expect(result.html.contains("2001:0db8:0000:0000:0000:ff00:0042:8329"))
    }

    @Test("A MAC address inside a table cell is left untouched")
    func macAddressInTableCellIsUntouched() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render(
            "| Device | MAC |\n| --- | --- |\n| router | a0:08:f3:e5:fa:d9 |",
            options: opts
        )
        #expect(result.html.contains("a0:08:f3:e5:fa:d9"))
        #expect(!result.html.contains("🌐"))
    }

    @Test("A genuine standalone shortcode still converts next to hex-alias-adjacent prose")
    func standaloneShortcodeStillConvertsNearHexText() {
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true
        let result = renderer.render("Nice one :de: and also :ab:", options: opts)
        #expect(result.html.contains("🇩🇪"))
        #expect(result.html.contains("🆎"))
    }

    @Test("The bundled shortcode table loads and is non-empty")
    func shortcodeTableLoads() {
        #expect(!MarkdownRenderer.emojiShortcodes.isEmpty)
        #expect(MarkdownRenderer.emojiShortcodes.count > 1800)
        #expect(MarkdownRenderer.emojiShortcodes["rocket"] == "🚀")
    }
}
