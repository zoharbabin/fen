@testable import FenCore
import Foundation
import Testing

/// End-to-end and unit proof for issue #26 (rules 2.1, 2.2, 3.1, 3.2, 3.3, plus the core visible
/// feature): drives `HTMLComposer.sanitizeCustomCSS`/`themeSwatchColors` directly for the
/// sanitization/fallback cases, and `HTMLComposer.compose` through a real `WKWebView` (via
/// `renderPreviewWebView`, the same helper `PreviewThemeCoverageTests.swift` uses) for the actual
/// custom-CSS-overrides-the-theme behavior.
@Suite("Custom CSS support")
struct CustomCSSSanitizationVerifyTest {
    @Test("Strips an @import rule referencing a remote URL")
    func stripsImportRule() {
        let sanitized = HTMLComposer.sanitizeCustomCSS(
            "@import url(https://evil.example/x.css); body { color: red; }"
        )
        #expect(!sanitized.contains("evil.example"))
        #expect(sanitized.contains("color: red"))
    }

    @Test("Strips a url(...) reference with a non-data scheme, case-insensitively")
    func stripsNonDataURL() {
        let sanitized = HTMLComposer.sanitizeCustomCSS(
            "body { background: url(https://evil.example/x.png); }"
        )
        #expect(!sanitized.contains("evil.example"))

        let mixedCase = HTMLComposer.sanitizeCustomCSS(
            "body { background: URL(HTTP://evil.example/x.png); }"
        )
        #expect(!mixedCase.contains("evil.example"))
    }

    @Test("Strips a </style breakout sequence, case-insensitively, with or without a closing >")
    func stripsStyleCloseTagBreakout() {
        let sanitized = HTMLComposer.sanitizeCustomCSS(
            "body{color:red}</style><script>window.pwned=1</script><style>"
        )
        #expect(!sanitized.contains("</style"))
        #expect(sanitized.contains("color:red"))

        let mixedCase = HTMLComposer.sanitizeCustomCSS("body{color:red}</STYLE><script>x</script>")
        #expect(!mixedCase.lowercased().contains("</style"))

        let noCloseAngle = HTMLComposer.sanitizeCustomCSS("body{color:red}</style ><script>x</script>")
        #expect(!noCloseAngle.contains("</style"))
    }

    @Test("A legitimate data: URL survives unchanged, not stripped as a false positive")
    func preservesDataURL() {
        let css = "body { background: url(data:image/png;base64,AAAA); }"
        let sanitized = HTMLComposer.sanitizeCustomCSS(css)
        #expect(sanitized.contains("data:image/png;base64,AAAA"))
    }

    @Test("Enforces the character ceiling regardless of input length")
    func enforcesCharacterLimit() {
        let oversized = String(repeating: "a", count: 20000)
        let sanitized = HTMLComposer.sanitizeCustomCSS(oversized)
        #expect(sanitized.count <= HTMLComposer.customCSSCharacterLimit)
    }

    @Test("Malformed CSS never throws -- sanitization is text-level, not a full CSS parse")
    func malformedCSSNeverThrows() {
        let garbage = "{{{ not real css ;;; url(",
            unterminated = "body { color: "
        _ = HTMLComposer.sanitizeCustomCSS(garbage)
        _ = HTMLComposer.sanitizeCustomCSS(unterminated)
    }

    @Test("A theme with no parseable body background/text color returns nil, not a crash")
    func swatchFallsBackToNilGracefully() {
        // Solarized's body {} rule declares no background-color/color directly (they're set via
        // a separate `html body { ... }` override), so this is a real, expected nil -- not a bug.
        #expect(HTMLComposer.themeSwatchColors(cssFileName: "Solarized (Light)") == nil)
        #expect(HTMLComposer.themeSwatchColors(cssFileName: "NoSuchTheme") == nil)
    }

    @Test("A theme with a literal body background/text color resolves a swatch")
    func swatchResolvesForParseableTheme() {
        #expect(HTMLComposer.themeSwatchColors(cssFileName: "GitHub2") != nil)
        #expect(HTMLComposer.themeSwatchColors(cssFileName: "GitHub2 Dark") != nil)
    }

    @Test("Custom CSS is inlined and wins the cascade when enabled")
    @MainActor
    func customCSSAppliesWhenEnabled() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = "GitHub2"
            prefs.customCSSEnabled = true
            prefs.customCSS = "body { color: rgb(1, 2, 3); }"
        }
        let color = try await webView.evaluateJavaScript("getComputedStyle(document.body).color")
        #expect((color as? String) == "rgb(1, 2, 3)")
    }

    @Test("Custom CSS has no effect while disabled, even with text present")
    @MainActor
    func customCSSIgnoredWhenDisabled() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = "GitHub2"
            prefs.customCSSEnabled = false
            prefs.customCSS = "body { color: rgb(1, 2, 3); }"
        }
        let color = try await webView.evaluateJavaScript("getComputedStyle(document.body).color")
        #expect((color as? String) != "rgb(1, 2, 3)")
    }

    @Test("An @import/url network vector in custom CSS never reaches the composed document")
    @MainActor
    func networkVectorNeverReachesComposedDocument() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = "GitHub2"
            prefs.customCSSEnabled = true
            prefs.customCSS = "@import url(https://evil.example/x.css); body { color: rgb(4, 5, 6); }"
        }
        let color = try await webView.evaluateJavaScript("getComputedStyle(document.body).color")
        #expect((color as? String) == "rgb(4, 5, 6)", "the rest of the rule must still apply")
        let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
        #expect(!((html as? String ?? "").contains("evil.example")))
    }

    @Test("A </style breakout in custom CSS never executes injected script in the real preview")
    @MainActor
    func styleBreakoutNeverExecutesInComposedDocument() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = "GitHub2"
            prefs.customCSSEnabled = true
            prefs.customCSS = "body{color:rgb(7, 8, 9)}</style><script>window.fenPwned=true</script><style>"
        }
        let pwned = try await webView.evaluateJavaScript("window.fenPwned === true")
        #expect((pwned as? Bool ?? false) == false, "the injected <script> must never execute")
        let color = try await webView.evaluateJavaScript("getComputedStyle(document.body).color")
        #expect((color as? String) == "rgb(7, 8, 9)", "the rest of the rule must still apply")
    }

    @Test("Empty or disabled custom CSS composes byte-identical to the feature not existing")
    @MainActor
    func emptyCustomCSSComposesIdentically() {
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("# Hello")

        let disabled = Preferences()
        disabled.customCSSEnabled = false

        let enabledButEmpty = Preferences()
        enabledButEmpty.customCSSEnabled = true
        enabledButEmpty.customCSS = ""

        let composer = HTMLComposer()
        let htmlA = composer.compose(title: nil, body: rendered.html, preferences: disabled)
        let htmlB = composer.compose(title: nil, body: rendered.html, preferences: enabledButEmpty)
        #expect(htmlA == htmlB)
    }
}
