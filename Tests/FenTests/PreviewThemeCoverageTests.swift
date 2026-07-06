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
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = themeName
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

    @Test("Mermaid picks the dark diagram theme only for themes named *Dark*", arguments: allThemes)
    @MainActor
    func mermaidThemeFollowsPreviewTheme(themeName: String) async throws {
        let webView = try await renderPreviewWebView(markdown: "text") { prefs in
            prefs.htmlStyleName = themeName
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
