import Foundation
import SwiftUI

// MARK: - Appearance Resolution (issue #25), Custom CSS (issue #26), Available Styles

/// One theme "family" a user picks from the CSS Theme / Print Theme pickers -- a single named
/// choice that resolves to a light or dark bundled CSS file depending on `Preferences
/// .previewAppearanceMode` (issue #98's redesign: Appearance is the *only* control for light/dark,
/// so the theme picker itself never lists light/dark variants separately). `GitHub` has no dark
/// counterpart and is deliberately given `darkFileName: nil` -- `resolvedFileName` falls back to
/// `lightFileName` unchanged for that case (rule 3.1).
public struct ThemeFamily: Sendable, Equatable {
    public let name: String
    public let lightFileName: String
    public let darkFileName: String?
}

public extension HTMLComposer {
    /// The 4 bundled theme families, covering all 7 `Styles/*.css` files. `Solarized`'s family
    /// name deliberately differs from either of its filenames (`Solarized (Light)`/`Solarized
    /// (Dark)`) -- every other family's name already matches its light filename, kept as-is so
    /// existing persisted `htmlStyleName`/`printStyleName` values for those three normalize to
    /// themselves for free.
    static let themeFamilies: [ThemeFamily] = [
        ThemeFamily(name: "Clearness", lightFileName: "Clearness", darkFileName: "Clearness Dark"),
        ThemeFamily(name: "GitHub", lightFileName: "GitHub", darkFileName: nil),
        ThemeFamily(name: "GitHub2", lightFileName: "GitHub2", darkFileName: "GitHub2 Dark"),
        ThemeFamily(name: "Solarized", lightFileName: "Solarized (Light)", darkFileName: "Solarized (Dark)"),
    ]

    static func availableThemeFamilyNames() -> [String] {
        themeFamilies.map(\.name).sorted()
    }

    /// Maps an exact bundled CSS filename (as stored in `DocumentPreviewOverrides.styleName`,
    /// which always validates against `availablePreviewStyles()`) back to its family name, e.g.
    /// `"GitHub2 Dark"` -> `"GitHub2"`. Also used to normalize legacy persisted
    /// `htmlStyleName`/`printStyleName` values that predate this family model. A name that
    /// already is a family name, or doesn't match any known filename, is returned unchanged
    /// (rule 3.2) -- this function never fails, throws, or returns an empty string.
    static func familyName(forFileName fileName: String) -> String {
        themeFamilies.first { $0.lightFileName == fileName || $0.darkFileName == fileName }?.name ?? fileName
    }

    /// Resolves a family name to the concrete CSS filename for the wanted polarity. An
    /// unrecognized family name is returned unchanged (rule 3.2), and a family with no dark
    /// counterpart (`GitHub`) always resolves to its light file (rule 3.1).
    static func resolvedFileName(forFamily family: String, wantsDark: Bool) -> String {
        guard let entry = themeFamilies.first(where: { $0.name == family }) else { return family }
        if wantsDark, let darkFileName = entry.darkFileName {
            return darkFileName
        }
        return entry.lightFileName
    }

    /// Resolves which CSS file to actually load, given the user's selected theme family, an
    /// optional family override (`Preferences.printStyleName` for `composeForPrint`), a
    /// document's own `fen:` front-matter override (an exact filename, converted to its family
    /// first), and the live/manual appearance state -- all three of `compose`, `composeForExport`,
    /// and `composeForPrint` share this one resolution path (issue #98), so a shared family
    /// (e.g. picking the same "GitHub2" for both) always renders identically. `appearanceOverride`
    /// (`Preferences.printAppearanceMode` for `composeForPrint`) lets print/export use their own
    /// light/dark polarity independent of the live preview's `previewAppearanceMode` -- issue #98
    /// intentionally keeps this a *per-purpose* override, not a single shared setting, since a
    /// user may want a dark on-screen preview but a light printout without touching either.
    static func resolveEffectiveStyleName(
        preferences: Preferences,
        familyOverride: String? = nil,
        appearanceOverride: PreviewAppearanceMode? = nil,
        documentOverrides: DocumentPreviewOverrides = .none
    ) -> String {
        let wantsDark = resolveWantsDark(preferences: preferences, appearanceOverride: appearanceOverride)
        let family = documentOverrides.styleName.map(familyName(forFileName:))
            ?? familyOverride
            ?? preferences.htmlStyleName
        return resolvedFileName(forFamily: family, wantsDark: wantsDark)
    }

    /// The shared light/dark resolution `resolveEffectiveStyleName` and
    /// `resolveEffectiveHighlightThemeName` both use, so a CSS theme and the syntax-highlighting
    /// theme always agree on polarity for the same render path (issue #100) -- neither the
    /// highlighting theme nor Mermaid gets its own Appearance control; both inherit whichever of
    /// `previewAppearanceMode`/`printAppearanceMode` applies.
    static func resolveWantsDark(preferences: Preferences, appearanceOverride: PreviewAppearanceMode? = nil) -> Bool {
        switch appearanceOverride ?? preferences.previewAppearanceMode {
        case .system: preferences.systemPrefersDarkAppearance
        case .light: false
        case .dark: true
        }
    }

    /// The 5 bundled syntax-highlighting theme families, covering all 9 `Highlight/themes/*.css`
    /// files -- mirrors `themeFamilies` above (issue #100). `default` has no dark counterpart,
    /// the same documented limitation `GitHub`'s CSS theme family has (rule 3.1).
    static let highlightThemeFamilies: [ThemeFamily] = [
        ThemeFamily(name: "atom-one", lightFileName: "atom-one-light", darkFileName: "atom-one-dark"),
        ThemeFamily(name: "default", lightFileName: "default", darkFileName: nil),
        ThemeFamily(name: "github", lightFileName: "github", darkFileName: "github-dark"),
        ThemeFamily(name: "solarized", lightFileName: "solarized-light", darkFileName: "solarized-dark"),
        ThemeFamily(name: "xcode", lightFileName: "xcode", darkFileName: "xcode-dark"),
    ]

    static func availableHighlightThemeFamilyNames() -> [String] {
        highlightThemeFamilies.map(\.name).sorted()
    }

    /// Maps an exact bundled highlighting CSS filename (e.g. `"github-dark"`) back to its family
    /// name, e.g. for normalizing a legacy persisted `htmlHighlightingThemeName` value that
    /// predates this family model (issue #100). A name that already is a family name, or doesn't
    /// match any known filename, is returned unchanged (rule 3.2).
    static func highlightFamilyName(forFileName fileName: String) -> String {
        highlightThemeFamilies.first { $0.lightFileName == fileName || $0.darkFileName == fileName }?.name
            ?? fileName
    }

    /// Resolves a highlighting theme family name to the concrete CSS filename for the wanted
    /// polarity. An unrecognized family name is returned unchanged (rule 3.2), and `default`
    /// (no dark counterpart) always resolves to its light file (rule 3.1).
    static func resolvedHighlightFileName(forFamily family: String, wantsDark: Bool) -> String {
        guard let entry = highlightThemeFamilies.first(where: { $0.name == family }) else { return family }
        if wantsDark, let darkFileName = entry.darkFileName {
            return darkFileName
        }
        return entry.lightFileName
    }

    /// Resolves which highlighting theme CSS file to load, inheriting light/dark polarity from
    /// the same Appearance setting the render path's CSS theme already resolved through
    /// (`appearanceOverride` is `Preferences.printAppearanceMode` for `composeForPrint`) -- issue
    /// #100 deliberately gives syntax highlighting no Appearance control of its own, the same way
    /// Mermaid already inherits from the resolved CSS theme filename.
    static func resolveEffectiveHighlightThemeName(
        preferences: Preferences,
        appearanceOverride: PreviewAppearanceMode? = nil
    ) -> String {
        let wantsDark = resolveWantsDark(preferences: preferences, appearanceOverride: appearanceOverride)
        return resolvedHighlightFileName(forFamily: preferences.htmlHighlightingThemeName, wantsDark: wantsDark)
    }

    /// Swatch colors for a theme family's row in the settings picker -- always drawn from the
    /// family's light file, since the picker no longer shows light/dark as separate rows.
    static func themeSwatchColors(forFamily family: String) -> (background: Color, text: Color)? {
        guard let entry = themeFamilies.first(where: { $0.name == family }) else { return nil }
        return themeSwatchColors(cssFileName: entry.lightFileName)
    }

    /// The largest custom CSS contribution `compose`/`composeForExport` will inline, regardless
    /// of how much text `Preferences.customCSS` holds -- a defensive bound against pathological
    /// input, not a feature limit any real stylesheet is expected to hit (rule 2.2).
    static let customCSSCharacterLimit = 8000

    /// Strips every `@import` rule, every `url(...)` reference whose scheme isn't `data:`, and
    /// any `</style` breakout sequence, so user-supplied CSS can never trigger a network fetch
    /// (rule 2.1) or escape the `<style>` tag `inlineStyle` wraps it in to run as live HTML/JS in
    /// the preview's WKWebView -- Fen's trust model is local-first with zero third-party runtime
    /// network loads, and custom CSS is the first feature where externally-authored text is
    /// inlined into the preview's WKWebView, so this is the one new content-injection point that
    /// needs its own guard. Operates as plain text substitution, never a full CSS parse, so
    /// malformed input can't throw (rule 3.2). Also enforces `customCSSCharacterLimit` (rule 2.2)
    /// as the final step.
    static func sanitizeCustomCSS(_ css: String) -> String {
        let truncated = String(css.prefix(customCSSCharacterLimit))
        guard let importRuleRegex, let nonDataURLRegex, let styleCloseTagRegex else { return truncated }
        var result = truncated as NSString
        result = importRuleRegex.stringByReplacingMatches(
            in: result as String, range: NSRange(location: 0, length: result.length), withTemplate: ""
        ) as NSString
        result = nonDataURLRegex.stringByReplacingMatches(
            in: result as String, range: NSRange(location: 0, length: result.length), withTemplate: ""
        ) as NSString
        result = styleCloseTagRegex.stringByReplacingMatches(
            in: result as String, range: NSRange(location: 0, length: result.length), withTemplate: ""
        ) as NSString
        return result as String
    }

    /// Parses a bundled theme's own `body { background-color: ...; color: ...; }` declaration
    /// into a small swatch for the settings picker (issue #26), without a full CSS parser.
    /// `color` is optional and defaults to black (the browser's own UA default for unset text
    /// color) -- `GitHub2.css`'s `body` rule legitimately never sets one. Returns `nil` (never
    /// throws) when a theme's `body` rule doesn't declare a background in a form this simple
    /// regex can find -- e.g. `Solarized (Light).css`/`Solarized (Dark).css` declare `body`'s
    /// background via a separate `html body { background-color: ... }` override rather than in
    /// the `body` rule itself, so those two themes show no swatch (rule 3.3).
    static func themeSwatchColors(cssFileName: String) -> (background: Color, text: Color)? {
        guard let backgroundColorRegex, let css = HTMLComposer().loadStyleCSS(named: cssFileName) else { return nil }
        guard let background = firstCaptureColor(backgroundColorRegex, in: css) else { return nil }
        let text = textColorRegex.flatMap { firstCaptureColor($0, in: css) } ?? .black
        return (background, text)
    }

    // MARK: - Available Styles

    static func availablePreviewStyles() -> [String] {
        guard let url = coreBundle.url(forResource: "Styles", withExtension: nil),
              let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return [] }
        return contents
            .filter { $0.pathExtension == "css" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

/// `@import`/non-`data:` `url(...)` regexes for `sanitizeCustomCSS`, compiled once. `try?`
/// rather than `try!` (matching `MarkdownRenderer+Alerts.swift`'s convention): the patterns
/// are compile-time literals that always compile, but `sanitizeCustomCSS` still degrades to
/// returning the untouched, truncated input rather than crashing if that ever changed.
private let importRuleRegex = try? NSRegularExpression(
    pattern: #"@import\s+[^;]*;"#, options: [.caseInsensitive]
)
private let nonDataURLRegex = try? NSRegularExpression(
    pattern: #"url\(\s*(?!['"]?data:)[^)]*\)"#, options: [.caseInsensitive]
)
/// Matches `</style` (with or without a closing `>`), case-insensitively -- `inlineStyle`
/// inlines this text directly inside a real `<style>` tag with no HTML escaping, so any
/// occurrence would close the style block early and let the rest of the string be parsed as
/// live markup/script in the preview `WKWebView`.
private let styleCloseTagRegex = try? NSRegularExpression(
    pattern: #"</style"#, options: [.caseInsensitive]
)

/// `body { background-color: ...; color: ...; }` regexes for `themeSwatchColors`. Anchored
/// to the start of a line (`^body`, multiline mode) so a compound selector like
/// `html body { ... }` -- a different, more specific rule -- never matches as if it were the
/// bare `body` rule; every bundled theme's own standalone `body {` rule starts at column 0.
private let backgroundColorRegex = try? NSRegularExpression(
    pattern: #"^body\s*\{[^}]*background-color:\s*([^;}\s]+)"#, options: [.caseInsensitive, .anchorsMatchLines]
)
private let textColorRegex = try? NSRegularExpression(
    pattern: #"^body\s*\{[^}]*(?<!background-)color:\s*([^;}\s]+)"#,
    options: [.caseInsensitive, .anchorsMatchLines]
)

private func firstCaptureColor(_ regex: NSRegularExpression, in css: String) -> Color? {
    let nsCSS = css as NSString
    guard let match = regex.firstMatch(in: css, range: NSRange(location: 0, length: nsCSS.length)),
          match.numberOfRanges > 1
    else { return nil }
    let value = nsCSS.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    if let hexColor = PlatformColor(hex: value) {
        return Color(hexColor)
    }
    if value.caseInsensitiveCompare("white") == .orderedSame {
        return .white
    }
    if value.caseInsensitiveCompare("black") == .orderedSame {
        return .black
    }
    return nil
}
