@testable import FenCore
import Foundation
import Testing

/// Verifies every bundled preview theme actually applies in a real WKWebView —
/// not just that the CSS file exists, but that its rules take effect on the
/// rendered DOM, across both light and dark themes.
@Suite("Preview theme coverage")
struct PreviewThemeCoverageTests {
    static let allThemes = HTMLComposer.availablePreviewStyles()

    @Test("Every bundled theme is discovered")
    func themesDiscovered() {
        #expect(Self.allThemes.count == 7, "Expected all 7 bundled Styles/*.css themes; got \(Self.allThemes)")
    }

    @Test("Each theme sets a distinct, non-default computed body background", arguments: allThemes)
    @MainActor
    func themeAppliesBackground(themeName: String) async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = themeName
        }
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        let value = bg as? String ?? ""
        #expect(
            !value.isEmpty && value != "rgba(0, 0, 0, 0)",
            "Theme \(themeName) left body background transparent/default"
        )
    }

    @Test("Dark themes render a visibly darker body background than light themes", arguments: allThemes)
    @MainActor
    func darkThemesAreDarker(themeName: String) async throws {
        // Pins appearance mode to the theme's own literal darkness so issue #25's
        // system-following resolution (HTMLComposer.resolveEffectiveStyleName) is a no-op
        // passthrough here -- this test is about each CSS file's own colors, not about
        // appearance-following, which has its own dedicated coverage in
        // PreviewAppearanceVerifyTest.swift.
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = themeName
            prefs.previewAppearanceMode = themeName.contains("Dark") ? .dark : .light
        }
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        guard let luma = luminance(fromRGBString: bg as? String ?? "") else {
            Issue.record("Could not parse computed background color for \(themeName): \(String(describing: bg))")
            return
        }
        if themeName.contains("Dark") {
            #expect(
                luma < 128,
                "Expected \(themeName) (a dark theme) to have a dark body background, got luminance \(luma)"
            )
        } else {
            #expect(
                luma >= 128,
                "Expected \(themeName) (a light theme) to have a light body background, got luminance \(luma)"
            )
        }
    }

    @Test("Loose task list checkbox stays inline with its text across every theme", arguments: allThemes)
    @MainActor
    func checkboxInlineAcrossThemes(themeName: String) async throws {
        let markdown = "- [ ] item one\n- [ ] item two\n\n  continuation text\n- [ ] item three"
        var opts = MarkdownRenderer.Options()
        opts.taskList = true
        let webView = try await renderPreviewWebView(markdown: markdown, options: opts) { prefs in
            prefs.htmlStyleName = themeName
        }
        let sameLineJS = """
        (function () {
            var checkbox = document.querySelector('li > input[type="checkbox"]');
            var p = checkbox ? checkbox.nextElementSibling : null;
            if (!checkbox || !p || p.tagName !== 'P') { return false; }
            var checkboxTop = checkbox.getBoundingClientRect().top;
            var pTop = p.getBoundingClientRect().top;
            return Math.abs(checkboxTop - pTop) < 5;
        })();
        """
        let sameLine = try await webView.evaluateJavaScript(sameLineJS)
        #expect((sameLine as? Bool) == true, "Theme \(themeName): expected checkbox and item text on the same line")
    }

    @Test("Loose bullet/ordered list marker stays inline with its item text across every theme", arguments: allThemes)
    @MainActor
    func looseListMarkerInlineAcrossThemes(themeName: String) async throws {
        // A blank line between items (or, as here, a bold lead-in followed by more text) makes
        // cmark-gfm treat the list as "loose" and wrap each item's content in <p>. Regression
        // coverage for the bug where the ::before bullet/number ended up on its own line above
        // that <p> instead of sharing a line box with it.
        let markdown = """
        - **Bold lead-in.** Rest of the first item's text.

        - Second item.

        1. **Bold lead-in.** Rest of the first item's text.

        2. Second item.
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlStyleName = themeName
        }
        let sameLineJS = """
        (function () {
            function markerAndTextShareLine(li) {
                // The first paragraph is `display: contents` (see listMarkerCSS), so it generates
                // no box of its own -- measure its first text node via a Range instead of the <p>.
                var p = li.querySelector('p');
                if (!p) { return false; }
                var walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT);
                var textNode = walker.nextNode();
                if (!textNode) { return false; }
                var range = document.createRange();
                range.selectNodeContents(textNode);
                var liTop = li.getBoundingClientRect().top;
                var textTop = range.getBoundingClientRect().top;
                return Math.abs(liTop - textTop) < 5;
            }
            var ulLi = document.querySelector('ul > li');
            var olLi = document.querySelector('ol > li');
            return JSON.stringify({
                ul: ulLi ? markerAndTextShareLine(ulLi) : null,
                ol: olLi ? markerAndTextShareLine(olLi) : null,
            });
        })();
        """
        let result = try await webView.evaluateJavaScript(sameLineJS)
        let json = try #require(result as? String)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String: Bool?].self, from: data)
        #expect(decoded["ul"] == true, "Theme \(themeName): expected <ul> marker and text on the same line")
        #expect(decoded["ol"] == true, "Theme \(themeName): expected <ol> marker and text on the same line")
    }

    @Test("Loose list item text starts flush after the marker, with no leading whitespace", arguments: allThemes)
    @MainActor
    func looseListItemHasNoLeadingWhitespace(themeName: String) async throws {
        // cmark-gfm emits a whitespace-only text node between <li> and a loose item's first <p>
        // (`<li>\n<p>text</p>...`). While that <p> was a block box this collapsed away invisibly;
        // `li > p:first-child { display: contents }` (see listMarkerCSS) turns it into ordinary
        // inline content sharing the marker's line box, rendering as a real leading space unless
        // listMarkerWhitespaceJS strips it. Regression coverage for that leading-space bug.
        let markdown = """
        - **Bold lead-in.** Rest of the first item's text.

        - Second item.
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlStyleName = themeName
        }
        let js = """
        (function () {
            var p = document.querySelector('ul > li > p');
            // display: contents leaves the DOM tree (and any whitespace-only sibling text node
            // right before p) untouched -- only p's own descendants participate in its box tree.
            // So the whitespace to detect is p.previousSibling, not anything inside p.
            var prev = p.previousSibling;
            return JSON.stringify(prev && prev.nodeType === Node.TEXT_NODE ? prev.textContent : null);
        })();
        """
        let result = try await webView.evaluateJavaScript(js)
        let json = try #require(result as? String)
        let data = try #require(json.data(using: .utf8))
        let text = try JSONDecoder().decode(String?.self, from: data)
        let message = "Theme \(themeName): expected no whitespace-only text node before item's <p>, " +
            "got \(String(reflecting: text))"
        #expect(text == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "\(message)")
    }

    @Test("A nested blockquote inside a list item renders its text inside its own border, not left of it")
    @MainActor
    func nestedBlockquoteInListItemDoesNotInheritHangingIndent() async throws {
        // `ol > li`/`ul > li`'s hanging `text-indent: -1.8em` (needed so the first line shares a
        // line box with the ::before marker) is an inherited property. `text-indent` shifts where
        // an element's text starts, not its border/padding box -- so without resetting it on later
        // children, a nested blockquote's border renders in the right place while its own text
        // drifts left by that same amount, ending up left of (rather than inside) the blockquote's
        // border. Measures the actual rendered text via Range, not the blockquote's box, since the
        // box position alone can't detect this class of bug.
        let markdown = """
        1. A list item with a nested blockquote:

           > Quoted text inside a list item.
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlStyleName = "GitHub2"
        }
        let js = """
        (function () {
            var li = document.querySelector('ol > li');
            var bq = li.querySelector('blockquote');
            var p = bq.querySelector('p');
            var walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT);
            var textNode = walker.nextNode();
            var range = document.createRange();
            range.selectNodeContents(textNode);
            return JSON.stringify({
                bqLeft: bq.getBoundingClientRect().left,
                textLeft: range.getBoundingClientRect().left,
            });
        })();
        """
        let result = try await webView.evaluateJavaScript(js)
        let json = try #require(result as? String)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String: Double].self, from: data)
        let bqLeft = try #require(decoded["bqLeft"])
        let textLeft = try #require(decoded["textLeft"])
        let message = "Expected blockquote text (left: \(textLeft)) inside its border (left: \(bqLeft)), " +
            "not drifted left of it from an inherited hanging indent"
        #expect(textLeft >= bqLeft, "\(message)")
    }

    @Test("Each of the 5 alert types renders a visually distinct border color across every theme", arguments: allThemes)
    @MainActor
    func alertsRenderDistinctColorsAcrossThemes(themeName: String) async throws {
        let types = ["note", "tip", "important", "warning", "caution"]
        let markdown = types.map { "> [!\($0.uppercased())]\n> Body for \($0)." }.joined(separator: "\n\n")
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let webView = try await renderPreviewWebView(markdown: markdown, options: opts) { prefs in
            prefs.htmlStyleName = themeName
        }

        var borderColors: Set<String> = []
        for type in types {
            let js = "getComputedStyle(document.querySelector('.markdown-alert-\(type)')).borderLeftColor"
            let color = try await webView.evaluateJavaScript(js) as? String ?? ""
            #expect(!color.isEmpty, "Theme \(themeName): expected a border-left-color for alert type \(type)")
            borderColors.insert(color)
        }
        #expect(
            borderColors.count == types.count,
            "Theme \(themeName): expected all 5 alert types to have distinct border colors, got \(borderColors)"
        )
    }

    @Test("Mermaid picks the dark diagram theme only for themes named *Dark*", arguments: allThemes)
    @MainActor
    func mermaidThemeFollowsPreviewTheme(themeName: String) async throws {
        // Same pin as darkThemesAreDarker above -- isolates this test from issue #25's
        // appearance-resolution re-pairing so it keeps testing the literal theme's own Mermaid
        // theme selection.
        let webView = try await renderPreviewWebView(markdown: "text") { prefs in
            prefs.htmlStyleName = themeName
            prefs.previewAppearanceMode = themeName.contains("Dark") ? .dark : .light
            prefs.htmlMermaid = true
        }
        let mermaidTheme = try await webView.evaluateJavaScript("window.__fenMermaidTheme")
        let expected = themeName.contains("Dark") ? "dark" : "default"
        #expect((mermaidTheme as? String) == expected, "Theme \(themeName) expected Mermaid theme '\(expected)'")
    }
}

/// Parses a CSS `rgb(r, g, b)` / `rgba(r, g, b, a)` string and returns perceptual luminance (0-255).
private func luminance(fromRGBString value: String) -> Double? {
    let digits = value
        .trimmingCharacters(in: CharacterSet(charactersIn: "rgba() "))
        .split(separator: ",")
        .prefix(3)
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard digits.count == 3 else { return nil }
    return 0.2126 * digits[0] + 0.7152 * digits[1] + 0.0722 * digits[2]
}
