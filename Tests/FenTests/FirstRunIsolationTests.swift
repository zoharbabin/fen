@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #37, rule 1.1: two `Preferences` instances never share or leak
/// `hasCompletedFirstRun` state -- mirrors `PreviewAppearanceIsolationTests.swift`'s
/// two-instance pattern.
struct FirstRunIsolationTests {
    @Test @MainActor
    func twoInstancesNeverShareFirstRunState() throws {
        let prefsA = try Preferences(defaults: #require(UserDefaults(suiteName: "firstrun.iso.\(UUID().uuidString)")))
        let prefsB = try Preferences(defaults: #require(UserDefaults(suiteName: "firstrun.iso.\(UUID().uuidString)")))

        _ = FirstRunContent.welcomeDocumentText(preferences: prefsA)

        #expect(prefsA.hasCompletedFirstRun)
        #expect(
            !prefsB.hasCompletedFirstRun,
            "consuming instance A's first-run welcome document must never affect instance B"
        )
    }

    @Test @MainActor
    func welcomeDocumentTextReturnsNilOnceConsumed() throws {
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: "firstrun.iso.\(UUID().uuidString)")))

        let first = FirstRunContent.welcomeDocumentText(preferences: prefs)
        let second = FirstRunContent.welcomeDocumentText(preferences: prefs)

        #expect(first != nil)
        #expect(second == nil)
    }
}
