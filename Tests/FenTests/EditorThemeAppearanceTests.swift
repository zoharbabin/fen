@testable import FenCore
import Foundation
import Testing

/// Proves issue #126: the Editor Theme picker splits into an independent Theme (family) +
/// Appearance pair, mirroring the Rendering tab's own split (issue #98) and the highlighting
/// theme family precedent (issue #100) -- plus the advanced-override escape hatch and the
/// migration path for a legacy flat `editorStyleName` value.
struct EditorThemeAppearanceTests {
    @Test @MainActor
    func resolvesCuratedFamilyAgainstEachAppearanceMode() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "editor.theme.\(UUID().uuidString)"))
        )
        preferences.editorThemeFamily = "github"

        preferences.editorAppearanceMode = .light
        #expect(MarkdownSyntaxHighlighter.resolveEditorThemeName(preferences: preferences) == "github")

        preferences.editorAppearanceMode = .dark
        #expect(MarkdownSyntaxHighlighter.resolveEditorThemeName(preferences: preferences) == "github-dark")

        preferences.editorAppearanceMode = .system
        preferences.systemPrefersDarkAppearance = true
        #expect(MarkdownSyntaxHighlighter.resolveEditorThemeName(preferences: preferences) == "github-dark")

        preferences.systemPrefersDarkAppearance = false
        #expect(MarkdownSyntaxHighlighter.resolveEditorThemeName(preferences: preferences) == "github")
    }

    @Test @MainActor
    func advancedOverrideWinsOverFamilyAndAppearance() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "editor.theme.\(UUID().uuidString)"))
        )
        preferences.editorThemeFamily = "github"
        preferences.editorAppearanceMode = .dark
        preferences.editorAdvancedThemeOverride = "monokai"

        #expect(
            MarkdownSyntaxHighlighter.resolveEditorThemeName(preferences: preferences) == "monokai",
            "an advanced override must win outright, regardless of the family/appearance pickers' state"
        )
    }

    @Test @MainActor
    func unrecognizedFamilyNameIsReturnedUnchanged() throws {
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "editor.theme.\(UUID().uuidString)"))
        )
        preferences.editorThemeFamily = "not-a-real-family"

        #expect(MarkdownSyntaxHighlighter.resolveEditorThemeName(preferences: preferences) == "not-a-real-family")
    }

    @Test("A legacy editorStyleName matching a curated family's dark file migrates to that family + dark")
    func legacyDarkSuffixedFilenameMigratesToFamilyAndPinnedDarkAppearance() throws {
        let suite = try #require(UserDefaults(suiteName: "editor.theme.\(UUID().uuidString)"))
        suite.set("github-dark", forKey: "editorStyleName")

        let preferences = Preferences(defaults: suite)

        #expect(preferences.editorThemeFamily == "github")
        #expect(preferences.editorAppearanceMode == .dark)
        #expect(preferences.editorAdvancedThemeOverride == nil)
    }

    @Test("A legacy editorStyleName matching a curated family's light file migrates to that family + light")
    func legacyLightFilenameMigratesToFamilyAndPinnedLightAppearance() throws {
        let suite = try #require(UserDefaults(suiteName: "editor.theme.\(UUID().uuidString)"))
        suite.set("xcode", forKey: "editorStyleName")

        let preferences = Preferences(defaults: suite)

        #expect(preferences.editorThemeFamily == "xcode")
        #expect(preferences.editorAppearanceMode == .light)
        #expect(preferences.editorAdvancedThemeOverride == nil)
    }

    @Test("A legacy editorStyleName with no curated family (e.g. monokai) migrates into the advanced override")
    func legacyUncuratedThemeMigratesToAdvancedOverride() throws {
        let suite = try #require(UserDefaults(suiteName: "editor.theme.\(UUID().uuidString)"))
        suite.set("monokai", forKey: "editorStyleName")

        let preferences = Preferences(defaults: suite)

        #expect(preferences.editorThemeFamily == "xcode")
        #expect(preferences.editorAppearanceMode == .system)
        #expect(preferences.editorAdvancedThemeOverride == "monokai")
    }

    @Test("A fresh install with no legacy value gets today's defaults, unmigrated")
    func freshInstallGetsDefaults() throws {
        let suite = try #require(UserDefaults(suiteName: "editor.theme.\(UUID().uuidString)"))

        let preferences = Preferences(defaults: suite)

        #expect(preferences.editorThemeFamily == "xcode")
        #expect(preferences.editorAppearanceMode == .system)
        #expect(preferences.editorAdvancedThemeOverride == nil)
    }

    @Test("Migration only runs once -- a second load reads the new keys directly, not the legacy value")
    func migrationDoesNotReRunOnSubsequentLoads() throws {
        let suite = try #require(UserDefaults(suiteName: "editor.theme.\(UUID().uuidString)"))
        suite.set("monokai", forKey: "editorStyleName")

        let first = Preferences(defaults: suite)
        #expect(first.editorAdvancedThemeOverride == "monokai")

        // Simulate a user changing the family picker after the migration ran once.
        first.editorAdvancedThemeOverride = nil
        first.editorThemeFamily = "github"
        first.editorAppearanceMode = .dark

        let second = Preferences(defaults: suite)
        #expect(second.editorThemeFamily == "github")
        #expect(second.editorAppearanceMode == .dark)
        #expect(
            second.editorAdvancedThemeOverride == nil,
            "the legacy editorStyleName ('monokai') must never resurrect itself once the new keys exist"
        )
    }
}
