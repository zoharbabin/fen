@testable import FenCore
import Foundation
import Testing

/// End-to-end and unit proof for issue #25 (rules 3.1, 3.2, plus the core visible feature):
/// drives `HTMLComposer.resolveEffectiveStyleName` directly for the fallback/edge cases, and
/// `HTMLComposer.compose` through a real `WKWebView` (via `renderPreviewWebView`, the same
/// helper `PreviewThemeCoverageTests.swift` uses) for the actual appearance-following behavior.
@Suite("Dark-mode preview following system appearance")
struct PreviewAppearanceVerifyTest {
    private func preferences(
        styleName: String,
        mode: PreviewAppearanceMode,
        systemDark: Bool
    ) -> Preferences {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "appearance.verify.\(UUID().uuidString)")!)
        prefs.htmlStyleName = styleName
        prefs.previewAppearanceMode = mode
        prefs.systemPrefersDarkAppearance = systemDark
        return prefs
    }

    @Test(
        "A style with no dark counterpart falls back to itself unchanged under every mode/system combination",
        arguments: [
            (PreviewAppearanceMode.system, false),
            (PreviewAppearanceMode.system, true),
            (PreviewAppearanceMode.light, false),
            (PreviewAppearanceMode.light, true),
            (PreviewAppearanceMode.dark, false),
            (PreviewAppearanceMode.dark, true),
        ]
    )
    @MainActor
    func styleWithNoDarkCounterpartFallsBackUnchanged(mode: PreviewAppearanceMode, systemDark: Bool) {
        let prefs = preferences(styleName: "GitHub", mode: mode, systemDark: systemDark)
        #expect(HTMLComposer.resolveEffectiveStyleName(preferences: prefs) == "GitHub")
    }

    @Test("An unrecognized style name resolves to itself unchanged, never throwing or returning empty")
    @MainActor
    func unrecognizedStyleNameResolvesUnchanged() {
        let prefs = preferences(styleName: "NoSuchTheme", mode: .dark, systemDark: false)
        #expect(HTMLComposer.resolveEffectiveStyleName(preferences: prefs) == "NoSuchTheme")
    }

    @Test("System mode follows the live system appearance flag")
    @MainActor
    func systemModeFollowsLiveSystemFlag() {
        let darkSystem = preferences(styleName: "GitHub2", mode: .system, systemDark: true)
        #expect(HTMLComposer.resolveEffectiveStyleName(preferences: darkSystem) == "GitHub2 Dark")

        let lightSystem = preferences(styleName: "GitHub2", mode: .system, systemDark: false)
        #expect(HTMLComposer.resolveEffectiveStyleName(preferences: lightSystem) == "GitHub2")
    }

    @Test("A manual override wins over a contradicting system appearance flag")
    @MainActor
    func manualOverrideWinsOverSystemFlag() {
        let forcedDark = preferences(styleName: "GitHub2", mode: .dark, systemDark: false)
        #expect(
            HTMLComposer.resolveEffectiveStyleName(preferences: forcedDark) == "GitHub2 Dark",
            "forcing dark must override a light system flag"
        )

        let forcedLight = preferences(styleName: "GitHub2", mode: .light, systemDark: true)
        #expect(
            HTMLComposer.resolveEffectiveStyleName(preferences: forcedLight) == "GitHub2",
            "forcing light must override a dark system flag"
        )
    }

    @Test("A theme family always resolves the same file regardless of what it was 'already' set to")
    @MainActor
    func familyNameResolvesConsistentlyForWantedPolarity() {
        let prefs = preferences(styleName: "GitHub2", mode: .dark, systemDark: false)
        #expect(HTMLComposer.resolveEffectiveStyleName(preferences: prefs) == "GitHub2 Dark")
    }

    @Test("A dark system appearance renders a dark computed body background and picks the dark Mermaid theme")
    @MainActor
    func systemDarkRendersDarkBackgroundAndMermaidTheme() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = "GitHub2"
            prefs.previewAppearanceMode = .system
            prefs.systemPrefersDarkAppearance = true
            prefs.htmlMermaid = true
        }
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        let luma = luminance(fromRGBString: bg as? String ?? "")
        #expect((luma ?? 255) < 128, "expected a dark computed background when the system prefers dark")

        let mermaidTheme = try await webView.evaluateJavaScript("window.__fenMermaidTheme")
        #expect((mermaidTheme as? String) == "dark")
    }

    @Test("A light system appearance renders a light computed body background")
    @MainActor
    func systemLightRendersLightBackground() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = "GitHub2"
            prefs.previewAppearanceMode = .system
            prefs.systemPrefersDarkAppearance = false
        }
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        let luma = luminance(fromRGBString: bg as? String ?? "")
        #expect((luma ?? 0) >= 128, "expected a light computed background when the system prefers light")
    }

    @Test("A manual dark override renders a dark computed body background even under a light system appearance")
    @MainActor
    func manualDarkOverrideRendersDarkBackgroundUnderLightSystem() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = "GitHub2"
            prefs.previewAppearanceMode = .dark
            prefs.systemPrefersDarkAppearance = false
        }
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        let luma = luminance(fromRGBString: bg as? String ?? "")
        #expect((luma ?? 255) < 128, "a manual dark override must win over a light system appearance")
    }

    @Test("Forcing dark on a style with no dark counterpart still renders light, the documented limitation")
    @MainActor
    func forcingDarkOnGitHubStillRendersLight() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Hello") { prefs in
            prefs.htmlStyleName = "GitHub"
            prefs.previewAppearanceMode = .dark
            prefs.systemPrefersDarkAppearance = true
        }
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        let luma = luminance(fromRGBString: bg as? String ?? "")
        #expect((luma ?? 0) >= 128, "GitHub has no dark counterpart, so forcing dark must leave it visibly light")
    }
}

/// Parses a CSS `rgb(r, g, b)` / `rgba(r, g, b, a)` string and returns perceptual luminance
/// (0-255). Duplicated from `PreviewThemeCoverageTests.swift` rather than shared, since that
/// file's copy is `private` and this suite lives in a separate file.
private func luminance(fromRGBString value: String) -> Double? {
    let digits = value
        .trimmingCharacters(in: CharacterSet(charactersIn: "rgba() "))
        .split(separator: ",")
        .prefix(3)
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard digits.count == 3 else { return nil }
    return 0.299 * digits[0] + 0.587 * digits[1] + 0.114 * digits[2]
}
