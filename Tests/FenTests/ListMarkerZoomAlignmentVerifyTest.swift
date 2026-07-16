import AppKit
@testable import FenCore
import Foundation
import Testing
import WebKit

/// WebKit's `zoom` (used by `HTMLComposer.fontScaleCSS` to scale preview text) breaks the
/// layout link between a native `list-style: outside` marker and its `<li>`'s wrapped lines,
/// so wrapped lines drift right of the first line at any non-1 zoom factor. `HTMLComposer`
/// works around this with a counter/bullet `::before` plus a hanging indent, which never
/// depends on that marker/line-box relationship.
@Suite("List marker alignment under zoom")
struct ListMarkerZoomAlignmentVerifyTest {
    @Test("Wrapped list-item lines stay aligned with the first line under zoom", arguments: [
        "GitHub", "GitHub2", "GitHub2 Dark", "Clearness", "Clearness Dark",
        "Solarized (Light)", "Solarized (Dark)",
    ])
    @MainActor
    func wrappedLinesStayAligned(themeName: String) async throws {
        let longText = String(repeating: "word ", count: 40)
        let markdown = """
        1. \(longText)
        2. \(longText)

        - \(longText)
        - \(longText)
        """

        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlStyleName = themeName
            prefs.fontSize = Preferences.defaultFontSize * 2
        }

        let js = """
        (function () {
            function leftEdges(li) {
                var range = document.createRange();
                range.selectNodeContents(li);
                var rects = range.getClientRects();
                var lefts = [];
                for (var i = 0; i < rects.length; i++) { lefts.push(rects[i].left); }
                return lefts;
            }
            var olLi = document.querySelector('ol > li');
            var ulLi = document.querySelector('ul > li');
            return JSON.stringify({ ol: leftEdges(olLi), ul: leftEdges(ulLi) });
        })();
        """
        let result = try await webView.evaluateJavaScript(js)
        let json = try #require(result as? String)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String: [Double]].self, from: data)

        for (list, lefts) in decoded {
            let first = try #require(lefts.first)
            for left in lefts {
                #expect(
                    abs(left - first) < 1,
                    "\(themeName) <\(list)>: wrapped line left edge \(left) drifted from first line \(first)"
                )
            }
        }
    }

    @Test("Custom ol start= is preserved by the counter-reset fix")
    @MainActor
    func customStartPreserved() async throws {
        let markdown = """
        5. five
        6. six
        """
        let webView = try await renderPreviewWebView(markdown: markdown)
        let counterReset = try await webView.evaluateJavaScript(
            "document.querySelector('ol').style.counterReset"
        )
        #expect((counterReset as? String) == "fen-ol 4")
    }

    @Test("Task list checkbox keeps no bullet marker and stays inline with its text")
    @MainActor
    func taskListCheckboxUnaffected() async throws {
        let markdown = """
        - [ ] item one
        - [x] item two
        """
        var opts = MarkdownRenderer.Options()
        opts.taskList = true
        let webView = try await renderPreviewWebView(markdown: markdown, options: opts)

        let js = """
        (function () {
            var li = document.querySelector('li');
            var checkbox = li.querySelector('input[type="checkbox"]');
            var textNode = li.lastChild;
            var before = window.getComputedStyle(li, '::before').content;
            var checkboxTop = checkbox.getBoundingClientRect().top;
            var range = document.createRange();
            range.selectNodeContents(textNode);
            var textTop = range.getClientRects()[0].top;
            return JSON.stringify({
                beforeContent: before,
                sameLine: Math.abs(checkboxTop - textTop) < 5
            });
        })();
        """
        let result = try await webView.evaluateJavaScript(js)
        let json = try #require(result as? String)
        let data = try #require(json.data(using: .utf8))
        struct Decoded: Decodable { let beforeContent: String
            let sameLine: Bool
        }
        let decoded = try JSONDecoder().decode(Decoded.self, from: data)
        #expect(decoded.beforeContent == "none")
        #expect(decoded.sameLine)
    }
}
