import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// Issue #258: a pandoc grid table gets a notice in the preview instead of a wall of `+` and `-`.
@Suite("Grid table notice")
struct GridTableNoticeTests {
    private static let grid = """
    +-------+--------------------------+
    | Time  | Session                  |
    +=======+==========================+
    | 09:30 | Arrival, coffee and      |
    |       | breakfast                |
    +-------+--------------------------+
    | 10:00 | Welcome, Kaltura\\'s day  |
    +-------+--------------------------+
    """

    private static func render(_ markdown: String, notice: Bool = true) -> String {
        var options = MarkdownRenderer.Options()
        options.gridTableNotice = notice
        options.sourcePositions = true
        return MarkdownRenderer().render(markdown, options: options).html
    }

    @Test func gridTableBecomesANoticeThatKeepsTheSource() {
        let html = Self.render("Intro.\n\n\(Self.grid)\n\nOutro.")
        #expect(html.contains(MarkdownRenderer.gridTableNotice))
        #expect(html.contains("<pre>+-------+"))
        #expect(html.contains("| 10:00 | Welcome"))
        #expect(html.contains("Outro."))
        #expect(!html.contains("<table"))
    }

    @Test func noticeKeepsSourcePositionForScrollSync() {
        let html = Self.render("Intro.\n\n\(Self.grid)")
        #expect(html.contains(#"<div class="fen-notice" data-sourcepos="3:1-"#))
    }

    @Test func eachGridTableGetsItsOwnNotice() {
        let html = Self.render("\(Self.grid)\n\nBetween.\n\n\(Self.grid)")
        #expect(html.components(separatedBy: MarkdownRenderer.gridTableNotice).count == 3)
    }

    @Test func offByDefaultSoExportsKeepTheSource() {
        let html = Self.render(Self.grid, notice: false)
        #expect(!html.contains("fen-notice"))
    }

    @Test func fencedGridTableGetsNoNotice() {
        let html = Self.render("```\n\(Self.grid)\n```")
        #expect(!html.contains("fen-notice"))
    }

    @Test func pipeTablesAndPlusListsGetNoNotice() {
        let html = Self.render("| a | b |\n|---|---|\n| 1 | 2 |\n\n+ one\n+ two\n\n+--+ not a table")
        #expect(!html.contains("fen-notice"))
        #expect(html.contains("<table"))
    }

    @Test func smartPunctuationDoesNotHideTheBorders() {
        var options = MarkdownRenderer.Options()
        options.gridTableNotice = true
        options.smartPunctuation = true
        let html = MarkdownRenderer().render("+---+---+\n| a | b |\n+---+---+", options: options).html
        #expect(html.contains(MarkdownRenderer.gridTableNotice))
    }

    @Test func hardWrapDoesNotHideTheTableOrDoubleItsLines() {
        var options = MarkdownRenderer.Options()
        options.gridTableNotice = true
        options.hardBreaks = true
        let html = MarkdownRenderer().render(Self.grid, options: options).html
        #expect(html.contains(MarkdownRenderer.gridTableNotice))
        #expect(!html.contains("<br />"))
    }

    @Test func tableInsideABlockquoteOrLooseListGetsANotice() {
        let quoted = Self.render("> +--+--+\n> | a | b |\n> +--+--+")
        #expect(quoted.contains(MarkdownRenderer.gridTableNotice))
        let loose = Self.render("- item\n\n  +--+--+\n  | a | b |\n  +--+--+\n\n- next")
        #expect(loose.contains(MarkdownRenderer.gridTableNotice))
    }

    @Test func tableDirectlyAfterATextLineIsNotMatched() {
        let html = Self.render("Table: schedule\n+--+--+\n| a | b |\n+--+--+")
        #expect(!html.contains("fen-notice"))
    }

    @Test("The notice and the original text render in the real preview")
    @MainActor
    func noticeRendersInWebKit() async throws {
        var options = MarkdownRenderer.Options()
        options.gridTableNotice = true
        let webView = try await renderPreviewWebView(markdown: "Intro.\n\n\(Self.grid)", options: options)

        let js = """
        (function () {
            var box = document.querySelector('div.fen-notice');
            if (!box) { return 'no notice'; }
            var title = box.querySelector('p.fen-notice-title');
            var pre = box.querySelector('pre');
            var rect = box.getBoundingClientRect();
            var below = title.getBoundingClientRect().bottom <= pre.getBoundingClientRect().top + 1;
            var preRect = pre.getBoundingClientRect();
            var inside = preRect.top >= rect.top && preRect.bottom <= rect.bottom + 1 && preRect.left >= rect.left;
            var mono = getComputedStyle(pre).fontFamily.toLowerCase().indexOf('mono') >= 0
                || getComputedStyle(pre).fontFamily.toLowerCase().indexOf('menlo') >= 0
                || getComputedStyle(pre).fontFamily.toLowerCase().indexOf('courier') >= 0;
            return [title.textContent, pre.textContent.indexOf('| 09:30 |') >= 0, rect.height > 40, below, inside, mono]
                .join('|');
        })();
        """
        let result = try #require(await webView.evaluateJavaScript(js) as? String)
        #expect(result.hasPrefix("\(MarkdownRenderer.gridTableNotice)|true|true|true|true|"), "Got: \(result)")
        #expect(result.hasSuffix("|true"), "The source block should use a monospace font. Got: \(result)")
    }
}
