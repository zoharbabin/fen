@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #25, rule 1.1: two `Preferences` instances never share or leak
/// appearance state -- mirrors `AutosaveIsolationTests.swift`'s two-instance pattern.
struct PreviewAppearanceIsolationTests {
    @Test @MainActor
    func twoInstancesNeverShareAppearanceState() throws {
        let prefsA = try Preferences(defaults: #require(UserDefaults(suiteName: "appearance.iso.\(UUID().uuidString)")))
        let prefsB = try Preferences(defaults: #require(UserDefaults(suiteName: "appearance.iso.\(UUID().uuidString)")))

        prefsA.previewAppearanceMode = .dark
        prefsA.systemPrefersDarkAppearance = true
        prefsB.previewAppearanceMode = .light
        prefsB.systemPrefersDarkAppearance = false

        #expect(prefsA.previewAppearanceMode == .dark)
        #expect(prefsA.systemPrefersDarkAppearance)
        #expect(prefsB.previewAppearanceMode == .light)
        #expect(
            !prefsB.systemPrefersDarkAppearance,
            "setting instance A's appearance state must never affect instance B"
        )
    }

    @Test @MainActor
    func stylePairingTableIsSharedImmutableStateNotPerInstanceState() throws {
        // The pairing table is deliberately `static let` (rule 1.1's exemption for immutable
        // shared state) -- proves it can never be mutated through the resolution path.
        let before = HTMLComposer.styleAppearancePairs
        _ = try HTMLComposer.resolveEffectiveStyleName(preferences: Preferences(
            defaults: #require(UserDefaults(suiteName: "appearance.iso.table.\(UUID().uuidString)"))
        ))
        #expect(HTMLComposer.styleAppearancePairs == before)
    }
}
