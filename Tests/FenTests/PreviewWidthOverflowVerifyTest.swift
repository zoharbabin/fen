@testable import FenCore
import Foundation
import Testing
import WebKit

/// Reproduces an actual user report: at certain preview-pane widths, rendered content bled
/// past the right edge instead of staying contained. Root cause was a combination of two
/// independently reasonable pieces of CSS: several themes (GitHub, GitHub2, GitHub2 Dark,
/// Clearness, Clearness Dark) fix `body`'s width to 854px once the viewport crosses a 914px
/// `@media` breakpoint, and `HTMLComposer`'s `fontScaleCSS` applies `body { zoom: ... }` for
/// the font-size preference. `@media` breakpoints evaluate against the real, unzoomed
/// viewport, but `zoom` then re-multiplies body's own declared box (width and padding) by the
/// font-scale ratio -- so at any font size above the 14px default, the *rendered* box became
/// wider than the real viewport once the breakpoint was crossed, and stayed pinned there for
/// every wider width too. At the default font size (scale 1.0) nothing overflows, which is
/// why this went unnoticed until someone changed the font size and resized the window. Fixed
/// by multiplying each theme's fixed width/padding by `--fen-font-inverse-scale` (the same
/// variable `HTMLComposer` already uses to cancel `zoom` out for images/SVGs), so the
/// rendered box resolves back to the intended 854px regardless of font size. A DOM string
/// check can't see this -- it only shows up as an actual `getBoundingClientRect()` overflow
/// after real CSS `zoom` and `@media` evaluation in a live `WKWebView`.
@Suite("Preview width overflow")
struct PreviewWidthOverflowVerifyTest {
    @Test(
        "Rendered content never overflows the viewport, across every theme, width, and font size",
        arguments: [
            "GitHub",
            "GitHub2",
            "GitHub2 Dark",
            "Clearness",
            "Clearness Dark",
            "Solarized (Light)",
            "Solarized (Dark)",
        ]
    )
    @MainActor
    func contentNeverOverflowsViewport(themeName: String) async throws {
        let markdown = "Just a plain paragraph, no code block, no Mermaid, nothing fancy at all here."
        for fontSize in [14, 24, 8] {
            let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
                prefs.htmlStyleName = themeName
                prefs.fontSize = CGFloat(fontSize)
            }

            for width in stride(from: 300, through: 1000, by: 20) {
                webView.frame = NSRect(x: 0, y: 0, width: Double(width), height: 800)
                let resized = try await pollUntilTrue(webView, js: "window.innerWidth === \(width)")
                let resizeMessage = "Theme \(themeName) at font size \(fontSize): viewport never resized to \(width)"
                #expect(resized, Comment(rawValue: resizeMessage))
                let bodyRight = try await webView.evaluateJavaScript(
                    "document.body.getBoundingClientRect().right"
                ) as? Double ?? -1
                let failureMessage = "Theme \(themeName) at font size \(fontSize), viewport \(width): " +
                    "body right edge \(bodyRight) overflows the viewport"
                #expect(bodyRight <= Double(width) + 1, Comment(rawValue: failureMessage))
            }
        }
    }
}
