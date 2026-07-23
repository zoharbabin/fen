@testable import FenCore
import Foundation
import Testing

/// Proves issue #100: the syntax-highlighting theme has no Appearance control of its own --
/// it inherits light/dark polarity from `previewAppearanceMode` for the live preview and
/// `printAppearanceMode` (falling back to `previewAppearanceMode`) for print/export, the same
/// way Mermaid already inherits its polarity from the resolved CSS theme.
struct HighlightThemeAppearanceTests {
    @Test @MainActor
    func previewFollowsPreviewAppearanceModeForASharedFamily() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "highlight.theme.\(UUID().uuidString)"))
        )
        preferences.htmlHighlightingThemeName = "xcode"
        preferences.previewAppearanceMode = .dark

        let previewed = HTMLComposer().compose(title: nil, body: "<pre><code>x</code></pre>", preferences: preferences)

        #expect(
            previewed.contains("background:#1f2024"),
            "previewAppearanceMode=.dark must resolve xcode's dark highlighting file, without touching the picker"
        )
    }

    @Test @MainActor
    func previewFollowsPreviewAppearanceModeWhenLight() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "highlight.theme.\(UUID().uuidString)"))
        )
        preferences.htmlHighlightingThemeName = "xcode"
        preferences.previewAppearanceMode = .light

        let previewed = HTMLComposer().compose(title: nil, body: "<pre><code>x</code></pre>", preferences: preferences)

        #expect(previewed.contains("background:#fff"), "previewAppearanceMode=.light must resolve xcode's light file")
    }

    @Test @MainActor
    func printAppearanceModeOverridesPreviewAppearanceModeForHighlightingOnPrintOnly() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "highlight.theme.\(UUID().uuidString)"))
        )
        preferences.htmlHighlightingThemeName = "xcode"
        preferences.previewAppearanceMode = .dark
        preferences.printAppearanceMode = .light

        let printed = HTMLComposer().composeForPrint(
            title: nil,
            body: "<pre><code>x</code></pre>",
            preferences: preferences
        )
        let previewed = HTMLComposer().compose(title: nil, body: "<pre><code>x</code></pre>", preferences: preferences)

        #expect(
            printed.contains("background:#fff"),
            """
            printAppearanceMode=.light must resolve xcode's light highlighting file for print, even while the \
            live preview is pinned to dark -- highlighting must never require its own Appearance choice
            """
        )
        #expect(
            previewed.contains("background:#1f2024"),
            "the live preview must stay on xcode's dark highlighting file -- printAppearanceMode must never affect it"
        )
    }

    @Test @MainActor
    func printFallsBackToPreviewAppearanceModeWhenPrintAppearanceModeUnset() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "highlight.theme.\(UUID().uuidString)"))
        )
        preferences.htmlHighlightingThemeName = "xcode"
        preferences.previewAppearanceMode = .dark
        #expect(preferences.printAppearanceMode == nil)

        let printed = HTMLComposer().composeForPrint(
            title: nil,
            body: "<pre><code>x</code></pre>",
            preferences: preferences
        )

        #expect(
            printed.contains("background:#1f2024"),
            "with printAppearanceMode unset, print must follow previewAppearanceMode"
        )
    }

    @Test @MainActor
    func defaultFamilyHasNoDarkCounterpartAndStaysItsOwnStyle() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "highlight.theme.\(UUID().uuidString)"))
        )
        preferences.htmlHighlightingThemeName = "default"
        preferences.previewAppearanceMode = .dark

        let previewed = HTMLComposer().compose(title: nil, body: "<pre><code>x</code></pre>", preferences: preferences)

        #expect(
            previewed.contains("background:#f3f3f3"),
            "default has no dark counterpart, so it must resolve to its own single style regardless of Appearance"
        )
    }

    @Test @MainActor
    func legacyPersistedDarkSuffixedFilenameMigratesToItsFamilyNameOnLoad() throws {
        let suite = try #require(UserDefaults(suiteName: "highlight.theme.\(UUID().uuidString)"))
        suite.set("github-dark", forKey: "htmlHighlightingThemeName")

        let preferences = Preferences(defaults: suite)

        #expect(preferences.htmlHighlightingThemeName == "github")
    }
}
