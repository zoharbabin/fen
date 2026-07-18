@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #26, rule 1.1: two `Preferences` instances never share or leak
/// custom-CSS state -- mirrors `PreviewAppearanceIsolationTests.swift`'s two-instance pattern.
struct CustomCSSIsolationTests {
    @Test @MainActor
    func twoInstancesNeverShareCustomCSSState() throws {
        let prefsA = try Preferences(defaults: #require(UserDefaults(suiteName: "customcss.iso.\(UUID().uuidString)")))
        let prefsB = try Preferences(defaults: #require(UserDefaults(suiteName: "customcss.iso.\(UUID().uuidString)")))

        prefsA.customCSSEnabled = true
        prefsA.customCSS = "body { color: red; }"
        prefsB.customCSSEnabled = false
        prefsB.customCSS = "body { color: blue; }"

        #expect(prefsA.customCSSEnabled)
        #expect(prefsA.customCSS == "body { color: red; }")
        #expect(!prefsB.customCSSEnabled)
        #expect(
            prefsB.customCSS == "body { color: blue; }",
            "setting instance A's custom CSS must never affect instance B"
        )
    }
}
