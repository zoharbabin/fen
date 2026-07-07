@testable import FenCore
import Foundation
import Testing

/// Proves the universal font-size preference scales text-bearing preview content
/// while leaving images and Mermaid diagrams at their natural size, and that each
/// rendered diagram gets its own pan/zoom controls. A string-content check on the
/// composed HTML can't see this — WebKit applies the `zoom` CSS and Mermaid's JS
/// builds the wrapper DOM only once real layout runs, so this loads real composed
/// HTML into a `WKWebView` and asserts on computed values, per the repo's e2e policy.
@Suite("Font scale and Mermaid zoom controls")
struct FontScaleAndMermaidZoomVerifyTest {
    @Test("Increasing fontSize scales body text but not images")
    @MainActor
    func fontSizeScalesTextNotImages() async throws {
        let markdown = "# Title\n\nParagraph text.\n\n![alt](https://example.com/x.png)"
        let defaultWebView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.fontSize = Preferences.defaultFontSize
        }
        let scaledWebView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.fontSize = Preferences.defaultFontSize * 2
        }

        let defaultBodyZoom = try await defaultWebView.evaluateJavaScript("getComputedStyle(document.body).zoom")
        let scaledBodyZoom = try await scaledWebView.evaluateJavaScript("getComputedStyle(document.body).zoom")
        #expect((defaultBodyZoom as? String) == "1")
        #expect((scaledBodyZoom as? String) == "2")

        let imgZoomJS = "getComputedStyle(document.querySelector('img')).zoom"
        let defaultImgZoom = try await defaultWebView.evaluateJavaScript(imgZoomJS)
        let scaledImgZoom = try await scaledWebView.evaluateJavaScript(imgZoomJS)
        // The image's own inverse zoom cancels the ancestor body zoom it inherits,
        // so the image renders at the same effective size regardless of fontSize.
        #expect((defaultImgZoom as? String) == "1")
        #expect((scaledImgZoom as? String) == "0.5")
    }

    @Test("Each rendered Mermaid diagram gets its own pan/zoom controls")
    @MainActor
    func mermaidDiagramsGetZoomControls() async throws {
        let markdown = """
        ```mermaid
        graph TD
        A --> B
        ```

        ```mermaid
        graph TD
        C --> D
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlMermaid = true
        }

        let hasTwoDiagrams = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-container svg').length === 2"
        )
        #expect(hasTwoDiagrams, "Expected two independently wrapped Mermaid diagrams")

        let eachHasControlsJS = """
        (function () {
            var containers = document.querySelectorAll('.fen-mermaid-container');
            if (containers.length !== 2) { return false; }
            for (var i = 0; i < containers.length; i++) {
                var c = containers[i];
                if (!c.querySelector('.fen-mermaid-zoom-in')) { return false; }
                if (!c.querySelector('.fen-mermaid-zoom-out')) { return false; }
                if (!c.querySelector('.fen-mermaid-zoom-reset')) { return false; }
                if (!c.querySelector('.fen-mermaid-viewport')) { return false; }
            }
            return true;
        })();
        """
        let eachHasControls = try await webView.evaluateJavaScript(eachHasControlsJS)
        #expect((eachHasControls as? Bool) == true, "Expected every Mermaid diagram to have its own zoom controls")
    }

    @Test("Mermaid zoom-in button scales only its own diagram")
    @MainActor
    func mermaidZoomInIsScopedPerDiagram() async throws {
        let markdown = """
        ```mermaid
        graph TD
        A --> B
        ```

        ```mermaid
        graph TD
        C --> D
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlMermaid = true
        }

        let ready = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-container svg').length === 2"
        )
        #expect(ready)

        _ = try await webView.evaluateJavaScript("""
        document.querySelectorAll('.fen-mermaid-zoom-in')[0].click();
        """)

        let firstScaleJS = "document.querySelectorAll('.fen-mermaid-pan')[0].style.transform"
        let secondScaleJS = "document.querySelectorAll('.fen-mermaid-pan')[1].style.transform"
        let firstScale = try await webView.evaluateJavaScript(firstScaleJS) as? String ?? ""
        let secondScale = try await webView.evaluateJavaScript(secondScaleJS) as? String ?? ""

        #expect(firstScale.contains("scale(1.25)"), "Expected the clicked diagram to scale up, got \(firstScale)")
        #expect(
            !secondScale.contains("scale(1.25)"),
            "Expected the other diagram to stay unaffected, got \(secondScale)"
        )
    }

    @Test("Zooming in grows the viewport instead of clipping the diagram")
    @MainActor
    func mermaidZoomGrowsViewportHeight() async throws {
        let markdown = """
        ```mermaid
        graph TD
        A --> B
        B --> C
        C --> D
        D --> E
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlMermaid = true
        }

        let ready = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-container svg').length === 1"
        )
        #expect(ready)

        let heightJS = "document.querySelector('.fen-mermaid-viewport').getBoundingClientRect().height"
        let naturalHeight = try await webView.evaluateJavaScript(heightJS) as? Double ?? 0

        // Click zoom-in enough times to push scale well past 1x, since a single
        // 0.25 step is small enough that rounding could mask a broken height calc.
        _ = try await webView.evaluateJavaScript("""
        for (var i = 0; i < 4; i++) { document.querySelector('.fen-mermaid-zoom-in').click(); }
        """)

        let zoomedHeight = try await webView.evaluateJavaScript(heightJS) as? Double ?? 0
        #expect(
            zoomedHeight > naturalHeight,
            "Expected viewport to grow past its natural height (\(naturalHeight)) when zoomed in, got \(zoomedHeight)"
        )
    }
}
