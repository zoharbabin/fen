@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #119: proves the emoji-shortcode transform pipeline holds no shared
/// mutable state across calls or instances, per rule 1.1 -- interleaves renders against two
/// different `MarkdownRenderer` instances and two different documents in one process and checks
/// neither call's result leaks into the other. Mirrors `GFMAlertsIsolationTests.swift`.
struct EmojiShortcodeIsolationTests {
    @Test func interleavedRendersAcrossInstancesDoNotShareState() {
        let rendererA = MarkdownRenderer()
        let rendererB = MarkdownRenderer()
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true

        let resultA1 = rendererA.render("Alpha :rocket:", options: opts)
        let resultB1 = rendererB.render("Beta :tada:", options: opts)
        let resultA2 = rendererA.render("Alpha :rocket:", options: opts)
        let resultB2 = rendererB.render("Beta :tada:", options: opts)

        #expect(resultA1.html == resultA2.html)
        #expect(resultB1.html == resultB2.html)
        #expect(resultA1.html.contains("🚀"))
        #expect(!resultA1.html.contains("🎉"))
        #expect(resultB1.html.contains("🎉"))
        #expect(!resultB1.html.contains("🚀"))
    }

    @Test func repeatedRendersOnDifferentShortcodesNeverAccumulateAcrossCalls() throws {
        let renderer = MarkdownRenderer()
        var opts = MarkdownRenderer.Options()
        opts.emojiShortcodes = true

        let shortcodes = ["rocket", "tada", "smile", "warning", "+1"]
        let results = shortcodes.map { renderer.render("Text :\($0):", options: opts).html }

        for (index, html) in results.enumerated() {
            let expectedEmoji = try #require(MarkdownRenderer.emojiShortcodes[shortcodes[index]])
            #expect(html.contains(expectedEmoji))
            for other in shortcodes where other != shortcodes[index] {
                if let otherEmoji = MarkdownRenderer.emojiShortcodes[other] {
                    #expect(!html.contains(otherEmoji))
                }
            }
        }
    }
}
