import Foundation
import SwiftUI

// MARK: - Appearance Resolution (issue #25), Custom CSS (issue #26), Available Styles

public extension HTMLComposer {
    /// Maps each light style to its dark counterpart and vice versa, covering the 3 pairs that
    /// already exist by filename convention. `GitHub` has no dark counterpart and is
    /// deliberately absent -- `resolveEffectiveStyleName` falls back to the original name
    /// unchanged for any style with no entry here (rule 3.1).
    static let styleAppearancePairs: [String: String] = [
        "Clearness": "Clearness Dark",
        "Clearness Dark": "Clearness",
        "GitHub2": "GitHub2 Dark",
        "GitHub2 Dark": "GitHub2",
        "Solarized (Light)": "Solarized (Dark)",
        "Solarized (Dark)": "Solarized (Light)",
    ]

    /// Resolves which CSS file to actually load, given the user's selected `htmlStyleName`,
    /// the manual appearance override, and the live system appearance. A style whose own
    /// darkness (via the existing `.contains("Dark")` convention) already matches what's
    /// wanted is returned unchanged; otherwise its pair is looked up. A style with no pair
    /// (`GitHub`) is returned unchanged regardless of what's wanted (rule 3.1), and an
    /// unrecognized style name is likewise returned unchanged (rule 3.2) -- this function
    /// never fails, throws, or returns an empty string.
    static func resolveEffectiveStyleName(
        preferences: Preferences,
        documentOverrides: DocumentPreviewOverrides = .none
    ) -> String {
        let wantsDark: Bool = switch preferences.previewAppearanceMode {
        case .system: preferences.systemPrefersDarkAppearance
        case .light: false
        case .dark: true
        }
        let styleName = documentOverrides.styleName ?? preferences.htmlStyleName
        guard styleName.contains("Dark") != wantsDark else { return styleName }
        return styleAppearancePairs[styleName] ?? styleName
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

    static func availableHighlightingThemes() -> [String] {
        guard let url = coreBundle.url(forResource: "themes", withExtension: nil, subdirectory: "Highlight"),
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
