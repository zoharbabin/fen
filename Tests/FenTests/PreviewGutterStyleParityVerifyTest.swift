@testable import FenCore
import Foundation
import Testing
import WebKit

/// End-to-end proof that the preview gutter's visual style (font, color, background, divider)
/// tracks the same OS-semantic values `EditorGutterRulerView`/`EditorGutterView_iOS` draw the
/// editor-pane gutter with, per the user's follow-up request on issue #21 ("same style as the
/// edit view ruler... identical in style and design... including color, sizes, background,
/// divider line"). Asserts on real computed style read back through a live `WKWebView`, not on
/// the raw CSS string, since `-apple-system-*` keywords only resolve to concrete color values
/// once WebKit actually renders them.
@Suite("Preview line-number gutter: style parity with the editor gutter")
struct PreviewGutterStyleParityVerifyTest {
    @Test(
        "A gutter number's font uses the system font with tabular digits, matching the editor's monospacedDigitSystemFont"
    )
    @MainActor
    func gutterFontMatchesEditorSystemFont() async throws {
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: "# Heading",
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 1
        )

        let variant = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.fen-gutter-line')).fontVariantNumeric"
        ) as? String
        let message = "Expected tabular-nums (the CSS equivalent of monospacedDigitSystemFont's " +
            "tabular digit guarantee), got \(variant ?? "nil")"
        #expect(variant == "tabular-nums", "\(message)")
    }

    @Test("A gutter number's color resolves to the OS's real secondary-label color, not the theme's text color")
    @MainActor
    func gutterColorResolvesToOSSecondaryLabel() async throws {
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: "# Heading",
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: 1
        )

        let color = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.fen-gutter-line')).color"
        ) as? String
        let controlColor = try await webView.evaluateJavaScript(
            "(function(){var d=document.createElement('div'); " +
                "d.style.color='-apple-system-secondary-label'; document.body.appendChild(d); " +
                "var c=getComputedStyle(d).color; d.remove(); return c;})()"
        ) as? String
        #expect(color != nil && color == controlColor, "Expected \(controlColor ?? "nil"), got \(color ?? "nil")")
    }

    @Test(
        "The gutter column has a ruler-style background and a right-edge divider, pinned to the viewport like the editor's own ruler"
    )
    @MainActor
    func gutterHasBackgroundRailAndDivider() async throws {
        let markdown = String(repeating: "Paragraph.\n\n", count: 20) + "# Heading"
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: markdown.components(separatedBy: "\n").count
        )

        let info = try await webView.evaluateJavaScript("""
        (function(){
          var rail = document.querySelector('.fen-gutter-rail');
          var style = getComputedStyle(rail);
          return JSON.stringify({
            position: style.position,
            background: style.backgroundColor,
            borderRight: style.borderRightWidth + ' ' + style.borderRightStyle,
            height: parseFloat(style.height),
            viewportHeight: window.innerHeight
          });
        })();
        """) as? String
        let data = try #require(info?.data(using: .utf8))
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(
            (parsed["position"] as? String) == "fixed",
            "Expected the rail pinned to the viewport, not the document"
        )
        #expect((parsed["background"] as? String) != "rgba(0, 0, 0, 0)", "Expected a real background fill, got none")
        #expect((parsed["borderRight"] as? String) == "1px solid", "Expected a 1px solid right-edge divider")

        let railHeight = try #require(parsed["height"] as? Double)
        let viewportHeight = try #require(parsed["viewportHeight"] as? Double)
        #expect(
            abs(railHeight - viewportHeight) < 1,
            "Expected the fixed rail to span the viewport, got rail=\(railHeight) viewport=\(viewportHeight)"
        )
    }

    @Test("The gutter's OS-semantic colors track previewAppearanceMode, not just the light default")
    @MainActor
    func gutterColorSchemeTracksPreviewAppearanceMode() async throws {
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true

        let lightWebView = try await renderPreviewWebView(
            markdown: "# Heading",
            options: opts,
            configurePreferences: {
                $0.editorShowLineNumbers = true
                $0.previewAppearanceMode = .light
            },
            sourceLineCount: 1
        )
        let darkWebView = try await renderPreviewWebView(
            markdown: "# Heading",
            options: opts,
            configurePreferences: {
                $0.editorShowLineNumbers = true
                $0.previewAppearanceMode = .dark
            },
            sourceLineCount: 1
        )

        let lightColor = try await lightWebView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.fen-gutter-line')).color"
        ) as? String
        let darkColor = try await darkWebView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.fen-gutter-line')).color"
        ) as? String

        let message = "Expected the gutter's OS-semantic color to differ between light and dark " +
            "previewAppearanceMode, got light=\(lightColor ?? "nil") dark=\(darkColor ?? "nil")"
        #expect(lightColor != nil && darkColor != nil && lightColor != darkColor, "\(message)")
    }

    @Test("The gutter rail never shrinks narrower than its number at small font sizes")
    @MainActor
    func gutterRailNeverNarrowerThanLineAtSmallFontSize() async throws {
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: "# Heading",
            options: opts,
            configurePreferences: {
                $0.editorShowLineNumbers = true
                $0.fontSize = Preferences.minFontSize
            },
            sourceLineCount: 1
        )

        let info = try await webView.evaluateJavaScript("""
        (function(){
          var rail = document.querySelector('.fen-gutter-rail');
          var line = document.querySelector('.fen-gutter-line');
          return JSON.stringify({
            railRight: rail.getBoundingClientRect().right,
            lineRight: line.getBoundingClientRect().right
          });
        })();
        """) as? String
        let data = try #require(info?.data(using: .utf8))
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let railRight = try #require(parsed["railRight"] as? Double)
        let lineRight = try #require(parsed["lineRight"] as? Double)

        let message = "Expected the gutter number to stay within the rail at the minimum font size, " +
            "got lineRight=\(lineRight) railRight=\(railRight)"
        #expect(lineRight <= railRight, "\(message)")
    }

    @Test("The gutter's background and divider don't move the gutter numbers or reintroduce the double-zoom drift")
    @MainActor
    func gutterRailDoesNotAffectNumberPositionAtNonDefaultFontSize() async throws {
        let markdown = String(repeating: "Paragraph.\n\n", count: 10) + "# Heading\n\nFinal paragraph."
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: {
                $0.editorShowLineNumbers = true
                $0.fontSize = 24
            },
            sourceLineCount: markdown.components(separatedBy: "\n").count
        )

        let diffs = try await webView.evaluateJavaScript("""
        (function(){
          var leaves = Array.from(document.querySelectorAll('[data-sourcepos]:not(td):not(th)'))
            .filter(function(el) { return !el.querySelector('[data-sourcepos]:not(td):not(th)'); });
          var gutterDivs = Array.from(document.querySelectorAll('.fen-gutter-line'));
          var byLine = {};
          gutterDivs.forEach(function(d){ byLine[d.textContent] = d; });

          var out = [];
          leaves.forEach(function(leaf) {
            var startLine = parseInt(leaf.getAttribute('data-sourcepos').split(':')[0], 10);
            var gutterDiv = byLine[String(startLine)];
            if (!gutterDiv) { return; }
            var range = document.createRange();
            range.selectNodeContents(leaf);
            var leafTop = range.getBoundingClientRect().top;
            var gutterTop = gutterDiv.getBoundingClientRect().top;
            out.push(gutterTop - leafTop);
          });
          return out;
        })();
        """) as? [Double]

        let diffList = try #require(diffs)
        #expect(!diffList.isEmpty)
        for diff in diffList {
            #expect(abs(diff) < 1, "Adding the background rail must not disturb gutter number alignment, got \(diff)px")
        }
    }
}
