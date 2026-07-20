@testable import FenCore
import Foundation
import Testing

/// Proves issue #82: `HTMLComposer.composeForPrint` lets Print… and Export to PDF… use a theme
/// different from the live on-screen preview, via `Preferences.printStyleName`.
struct PrintPDFThemeOverrideTests {
    @Test @MainActor
    func printStyleNameLeftAtDefaultFallsBackToHTMLStyleName() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "print.theme.\(UUID().uuidString)"))
        )
        preferences.htmlStyleName = "GitHub2 Dark"
        #expect(preferences.printStyleName == nil)

        let composed = HTMLComposer().composeForPrint(title: nil, body: "<p>Text</p>", preferences: preferences)

        #expect(composed.contains("background-color: #0d1117"), "must use GitHub2 Dark's own CSS, unchanged")
    }

    @Test @MainActor
    func printStyleNameSetOverridesHTMLStyleNameForPrintOnly() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "print.theme.\(UUID().uuidString)"))
        )
        preferences.htmlStyleName = "GitHub2 Dark"
        preferences.previewAppearanceMode = .dark
        preferences.printStyleName = "GitHub2"

        let printed = HTMLComposer().composeForPrint(title: nil, body: "<p>Text</p>", preferences: preferences)
        let previewed = HTMLComposer().compose(title: nil, body: "<p>Text</p>", preferences: preferences)

        #expect(printed.contains("background-color: white"), "printStyleName must override htmlStyleName for print")
        #expect(
            previewed.contains("background-color: #0d1117"),
            "the live preview must keep using htmlStyleName unaffected"
        )
    }
}
