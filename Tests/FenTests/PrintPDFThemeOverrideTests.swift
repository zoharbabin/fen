@testable import FenCore
import Foundation
import Testing

/// Proves issue #82: `HTMLComposer.composeForPrint` lets Print… and Export to PDF… use a theme
/// different from the live on-screen preview, via `Preferences.printStyleName`. Also proves
/// issue #98: `Preferences.printAppearanceMode` lets print/export use a different light/dark
/// polarity than the live preview's `previewAppearanceMode`, independently of it.
struct PrintPDFThemeOverrideTests {
    @Test @MainActor
    func printStyleNameLeftAtDefaultFallsBackToHTMLStyleName() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "print.theme.\(UUID().uuidString)"))
        )
        preferences.htmlStyleName = "GitHub2"
        preferences.previewAppearanceMode = .dark
        #expect(preferences.printStyleName == nil)

        let composed = HTMLComposer().composeForPrint(title: nil, body: "<p>Text</p>", preferences: preferences)

        #expect(composed.contains("background-color: #0d1117"), "must use GitHub2's dark file per Appearance")
    }

    @Test @MainActor
    func printStyleNameSetOverridesHTMLStyleNameForPrintOnly() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "print.theme.\(UUID().uuidString)"))
        )
        preferences.htmlStyleName = "GitHub2"
        preferences.previewAppearanceMode = .dark
        preferences.printStyleName = "GitHub2"

        let printed = HTMLComposer().composeForPrint(title: nil, body: "<p>Text</p>", preferences: preferences)
        let previewed = HTMLComposer().compose(title: nil, body: "<p>Text</p>", preferences: preferences)

        #expect(printed.contains("background-color: #0d1117"), "printStyleName must still follow Appearance")
        #expect(
            previewed.contains("background-color: #0d1117"),
            "the live preview must resolve identically since both share the same theme family"
        )
    }

    @Test @MainActor
    func printStyleNameCanUseADifferentFamilyWhilePolarityStillFollowsAppearanceByDefault() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "print.theme.\(UUID().uuidString)"))
        )
        preferences.htmlStyleName = "GitHub2"
        preferences.previewAppearanceMode = .dark
        preferences.printStyleName = "Clearness"
        #expect(preferences.printAppearanceMode == nil)

        let printed = HTMLComposer().composeForPrint(title: nil, body: "<p>Text</p>", preferences: preferences)

        #expect(
            printed.contains("background-color: #282a36"),
            """
            printStyleName picks a different family (Clearness), and with printAppearanceMode left at its \
            default (nil, "Same as Preview") it must still resolve Clearness's dark file since Appearance \
            is set to dark (issue #98)
            """
        )
    }

    @Test @MainActor
    func printAppearanceModeOverridesPreviewAppearanceModeForPrintOnly() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "print.theme.\(UUID().uuidString)"))
        )
        preferences.htmlStyleName = "GitHub2"
        preferences.previewAppearanceMode = .dark
        preferences.printAppearanceMode = .light

        let printed = HTMLComposer().composeForPrint(title: nil, body: "<p>Text</p>", preferences: preferences)
        let previewed = HTMLComposer().compose(title: nil, body: "<p>Text</p>", preferences: preferences)

        #expect(
            printed.contains("background-color: white"),
            """
            printAppearanceMode=.light must render GitHub2's light file for print, even while the live preview \
            is pinned to dark (issue #98) -- a user shouldn't have to flip Appearance to print light
            """
        )
        #expect(
            previewed.contains("background-color: #0d1117"),
            "the live preview must stay on GitHub2's dark file -- printAppearanceMode must never affect it"
        )
    }
}
