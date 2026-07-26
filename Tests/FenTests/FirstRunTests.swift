@testable import FenCore
import Foundation
import Testing

/// Proves issue #37's Phase-1 rules 4.1/5.1: the bundled welcome document exists, is
/// non-trivial content, and `MarkdownDocument.makeNew` returns it exactly once per
/// `Preferences` instance before falling back to blank.
struct FirstRunTests {
    @Test @MainActor
    func welcomeDocumentTextIsBundledAndNonEmpty() throws {
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: "firstrun.\(UUID().uuidString)")))

        let text = FirstRunContent.welcomeDocumentText(preferences: prefs)

        let unwrapped = try #require(text, "Welcome.md must resolve from the bundled Templates resource")
        #expect(unwrapped.contains("# Welcome to Fen"))
    }

    @Test @MainActor
    func makeNewReturnsWelcomeTextOnceThenBlank() throws {
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: "firstrun.\(UUID().uuidString)")))

        let firstDocument = MarkdownDocument.makeNew(preferences: prefs)
        #expect(!firstDocument.text.isEmpty)

        let secondDocument = MarkdownDocument.makeNew(preferences: prefs)
        #expect(secondDocument.text.isEmpty)
    }

    @Test @MainActor
    func makeNewOpensBlankWhenFirstRunAlreadyCompleted() throws {
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: "firstrun.\(UUID().uuidString)")))
        prefs.hasCompletedFirstRun = true

        let document = MarkdownDocument.makeNew(preferences: prefs)

        #expect(document.text.isEmpty)
    }
}
