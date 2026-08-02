import Foundation
import Highlightr

/// Editor syntax highlighting is performed live by Highlightr's
/// `CodeAttributedString` inside `MarkdownTextView`. This namespace just
/// exposes the list of available themes for the Settings picker.
@MainActor
enum MarkdownSyntaxHighlighter {
    /// Available Highlightr (highlight.js) themes, sorted alphabetically.
    static var availableThemes: [String] {
        (Highlightr()?.availableThemes() ?? []).sorted()
    }

    /// The 7 curated editor theme families, each a genuine `name`/`name-dark` (or `name-light`/
    /// `name-dark`) pair among the 271 bundled Highlightr themes -- mirrors `HTMLComposer
    /// .themeFamilies`/`highlightThemeFamilies`' own family-picker precedent (issues #98/#100),
    /// applied here to the editor's own `editorThemeFamily` (issue #126). Unlike `GitHub`/
    /// `default` elsewhere, every family here has a real dark counterpart -- there's no
    /// no-dark-fallback case among these seven.
    nonisolated static let editorThemeFamilies: [ThemeFamily] = [
        ThemeFamily(name: "a11y", lightFileName: "a11y-light", darkFileName: "a11y-dark"),
        ThemeFamily(name: "atom-one", lightFileName: "atom-one-light", darkFileName: "atom-one-dark"),
        ThemeFamily(name: "classic", lightFileName: "classic-light", darkFileName: "classic-dark"),
        ThemeFamily(name: "github", lightFileName: "github", darkFileName: "github-dark"),
        ThemeFamily(name: "gruvbox", lightFileName: "gruvbox-light", darkFileName: "gruvbox-dark"),
        ThemeFamily(name: "solarized", lightFileName: "solarized-light", darkFileName: "solarized-dark"),
        ThemeFamily(name: "xcode", lightFileName: "xcode", darkFileName: "xcode-dark"),
    ]

    static func availableEditorThemeFamilyNames() -> [String] {
        editorThemeFamilies.map(\.name).sorted()
    }

    /// Maps an exact bundled editor theme filename (e.g. `"github-dark"`) back to its family
    /// name, for normalizing a legacy persisted `editorStyleName` value that predates this family
    /// model (issue #126). A name that doesn't match any curated family's filename is returned
    /// unchanged (rule 3.2's precedent in `HTMLComposer.familyName`).
    nonisolated static func editorFamilyName(forFileName fileName: String) -> String {
        editorThemeFamilies.first { $0.lightFileName == fileName || $0.darkFileName == fileName }?.name
            ?? fileName
    }

    /// Resolves an editor theme family name to the concrete Highlightr theme filename for the
    /// wanted polarity. An unrecognized family name is returned unchanged rather than crashing
    /// (rule 4.3), matching `HTMLComposer.resolvedFileName`'s own fallback.
    nonisolated static func resolvedEditorFileName(forFamily family: String, wantsDark: Bool) -> String {
        guard let entry = editorThemeFamilies.first(where: { $0.name == family }) else { return family }
        if wantsDark, let darkFileName = entry.darkFileName {
            return darkFileName
        }
        return entry.lightFileName
    }

    /// Resolves which Highlightr theme to actually load into the live editor. `editorAdvancedThemeOverride`
    /// wins outright when set (rule 4.1); otherwise resolves `editorThemeFamily` + `editorAppearanceMode`
    /// (rule 4.2) -- independent of `previewAppearanceMode`, since the editor and preview are both visible
    /// at once in split view and a user may reasonably want them in different polarities.
    static func resolveEditorThemeName(preferences: Preferences) -> String {
        if let override = preferences.editorAdvancedThemeOverride {
            return override
        }
        let wantsDark: Bool = switch preferences.editorAppearanceMode {
        case .system: preferences.systemPrefersDarkAppearance
        case .light: false
        case .dark: true
        }
        return resolvedEditorFileName(forFamily: preferences.editorThemeFamily, wantsDark: wantsDark)
    }
}
