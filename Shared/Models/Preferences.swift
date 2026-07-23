import Foundation
import SwiftUI

/// User-facing choice for which appearance the preview should render in (issue #25).
/// `.system` means "follow `Preferences.systemPrefersDarkAppearance`"; `.light`/`.dark` pin
/// the preview independent of the system setting.
public enum PreviewAppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

@Observable
public final class Preferences {
    public nonisolated(unsafe) static let shared = Preferences()

    // MARK: - Markdown Extension Flags

    var extensionTables: Bool = true {
        didSet { defaults.set(extensionTables, forKey: "extensionTables")
            renderRevision += 1
        }
    }

    var extensionAutolink: Bool = true {
        didSet { defaults.set(extensionAutolink, forKey: "extensionAutolink")
            renderRevision += 1
        }
    }

    var extensionStrikethrough: Bool = true {
        didSet { defaults.set(extensionStrikethrough, forKey: "extensionStrikethrough")
            renderRevision += 1
        }
    }

    var extensionHighlight: Bool = false {
        didSet { defaults.set(extensionHighlight, forKey: "extensionHighlight")
            renderRevision += 1
        }
    }

    /// Matches MacDown's original default (footnotes rendered uncontrolled, effectively
    /// always on) rather than defaulting off like most other extension toggles here --
    /// see issue #53.
    var extensionFootnotes: Bool = true {
        didSet { defaults.set(extensionFootnotes, forKey: "extensionFootnotes")
            renderRevision += 1
        }
    }

    var extensionSmartyPants: Bool = false {
        didSet { defaults.set(extensionSmartyPants, forKey: "extensionSmartyPants")
            renderRevision += 1
        }
    }

    /// Defaults on (unlike `extensionHighlight`'s default-off): the `> [!TYPE]` marker is
    /// specific enough that accidental collision with real prose is effectively impossible,
    /// the same reasoning `extensionTables`/`extensionAutolink`/`extensionStrikethrough`
    /// already default on for -- see issue #29.
    var extensionAlerts: Bool = true {
        didSet { defaults.set(extensionAlerts, forKey: "extensionAlerts")
            renderRevision += 1
        }
    }

    var markdownManualRender: Bool = false {
        didSet { defaults.set(markdownManualRender, forKey: "markdownManualRender") }
    }

    // MARK: - Editor

    var editorFontName: String = "Menlo-Regular" {
        didSet { defaults.set(editorFontName, forKey: "editorFontName") }
    }

    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 48
    static let defaultFontSize: CGFloat = 14

    /// Universal font size, applied to both the editor and the rendered preview's text
    /// (headings, paragraphs, code, tables, quotes) — not to images or diagrams.
    ///
    /// Deliberately does *not* bump `renderRevision`: `PreviewWebView` applies a font-size
    /// change live via a CSS custom property instead of a full recompose/reload (see
    /// `Shared/Preview/ScrollSyncJS.swift`'s `fontScaleAssignmentJS`), so a zoom step never
    /// resets the preview's scroll position to the top.
    var fontSize: CGFloat = defaultFontSize {
        didSet {
            defaults.set(Double(fontSize), forKey: "editorFontSize")
        }
    }

    public func increaseFontSize() {
        fontSize = min(Self.maxFontSize, fontSize + 1)
    }

    public func decreaseFontSize() {
        fontSize = max(Self.minFontSize, fontSize - 1)
    }

    public func resetFontSize() {
        fontSize = Self.defaultFontSize
    }

    var editorAutoIncrementNumberedLists: Bool = true {
        didSet { defaults.set(editorAutoIncrementNumberedLists, forKey: "editorAutoIncrementNumberedLists") }
    }

    var editorConvertTabs: Bool = true {
        didSet { defaults.set(editorConvertTabs, forKey: "editorConvertTabs") }
    }

    var editorInsertPrefixInBlock: Bool = true {
        didSet { defaults.set(editorInsertPrefixInBlock, forKey: "editorInsertPrefixInBlock") }
    }

    var editorCompleteMatchingCharacters: Bool = true {
        didSet { defaults.set(editorCompleteMatchingCharacters, forKey: "editorCompleteMatchingCharacters") }
    }

    var editorSyncScrolling: Bool = true {
        didSet { defaults.set(editorSyncScrolling, forKey: "editorSyncScrolling") }
    }

    var editorSmartHome: Bool = true {
        didSet { defaults.set(editorSmartHome, forKey: "editorSmartHome") }
    }

    var editorStyleName: String = "xcode" {
        didSet { defaults.set(editorStyleName, forKey: "editorStyleName") }
    }

    var editorHorizontalInset: CGFloat = 15 {
        didSet { defaults.set(Double(editorHorizontalInset), forKey: "editorHorizontalInset") }
    }

    var editorVerticalInset: CGFloat = 30 {
        didSet { defaults.set(Double(editorVerticalInset), forKey: "editorVerticalInset") }
    }

    var editorLineSpacing: CGFloat = 3 {
        didSet { defaults.set(Double(editorLineSpacing), forKey: "editorLineSpacing") }
    }

    var editorWidthLimited: Bool = false {
        didSet { defaults.set(editorWidthLimited, forKey: "editorWidthLimited") }
    }

    var editorMaximumWidth: CGFloat = 800 {
        didSet { defaults.set(Double(editorMaximumWidth), forKey: "editorMaximumWidth") }
    }

    var editorOnRight: Bool = false {
        didSet { defaults.set(editorOnRight, forKey: "editorOnRight") }
    }

    var editorShowWordCount: Bool = false {
        didSet { defaults.set(editorShowWordCount, forKey: "editorShowWordCount") }
    }

    var editorScrollsPastEnd: Bool = true {
        didSet { defaults.set(editorScrollsPastEnd, forKey: "editorScrollsPastEnd") }
    }

    var editorEnsuresNewlineAtEndOfFile: Bool = true {
        didSet { defaults.set(editorEnsuresNewlineAtEndOfFile, forKey: "editorEnsuresNewlineAtEndOfFile") }
    }

    // MARK: - HTML / Preview

    /// A theme *family* name (e.g. `"GitHub2"`), never an exact light/dark filename -- the
    /// Appearance setting (`previewAppearanceMode`) determines which of a family's bundled CSS
    /// files loads for the live preview (issue #98). `loadHTMLDefaults` normalizes any pre-#96
    /// persisted value (which could be a dark-suffixed filename like `"GitHub2 Dark"`) to its
    /// family name on load, so this property itself never needs to special-case that.
    var htmlStyleName: String = "GitHub2" {
        didSet { defaults.set(htmlStyleName, forKey: "htmlStyleName")
            renderRevision += 1
        }
    }

    /// Overrides `htmlStyleName` for Print… and Export to PDF… only (issue #82) -- `nil` (the
    /// default) means "follow whatever `htmlStyleName` currently is," so printing/exporting
    /// behaves exactly as before for anyone who never touches this setting. Also a family name,
    /// never an exact filename (issue #98). Polarity (light vs. dark) is controlled separately by
    /// `printAppearanceMode`, so a document can be printed in a different theme *family* than the
    /// preview, in a different polarity, or both.
    var printStyleName: String? {
        didSet { defaults.set(printStyleName, forKey: "printStyleName") }
    }

    /// Manual override for the preview's light/dark appearance (issue #25). `.system` (the
    /// default) makes `HTMLComposer` follow `systemPrefersDarkAppearance` instead.
    var previewAppearanceMode: PreviewAppearanceMode = .system {
        didSet { defaults.set(previewAppearanceMode.rawValue, forKey: "previewAppearanceMode")
            renderRevision += 1
        }
    }

    /// Overrides `previewAppearanceMode` for Print… and Export to PDF… only (issue #98) -- `nil`
    /// (the default) means "follow whatever `previewAppearanceMode` currently is," mirroring
    /// `printStyleName`'s own nil-means-follow-preview convention. Set independently, a user can
    /// print/export light while previewing dark on screen (or vice versa) without touching the
    /// live preview's appearance at all.
    var printAppearanceMode: PreviewAppearanceMode? {
        didSet { defaults.set(printAppearanceMode?.rawValue, forKey: "printAppearanceMode") }
    }

    /// Live system light/dark state, set by `SplitEditorView` from SwiftUI's
    /// `@Environment(\.colorScheme)` -- not a user preference, so unlike every other property
    /// in this file, this one is never written to `UserDefaults`: it should always reflect
    /// the system's *current* appearance, never a stale persisted snapshot from a previous run.
    var systemPrefersDarkAppearance: Bool = false {
        didSet { renderRevision += 1 }
    }

    /// Whether `customCSS` is layered on top of the selected theme (issue #26). Kept separate
    /// from the text itself so a user can author CSS, toggle it off to compare against the
    /// bundled theme, and toggle back on without retyping.
    var customCSSEnabled: Bool = false {
        didSet { defaults.set(customCSSEnabled, forKey: "customCSSEnabled")
            renderRevision += 1
        }
    }

    /// User-authored CSS, layered last (after every bundled/extension style) so it wins the
    /// cascade by source order alone (issue #26). Passed through `HTMLComposer.sanitizeCustomCSS`
    /// before being inlined -- never trust this string directly.
    var customCSS: String = "" {
        didSet { defaults.set(customCSS, forKey: "customCSS")
            renderRevision += 1
        }
    }

    var htmlDetectFrontMatter: Bool = true {
        didSet { defaults.set(htmlDetectFrontMatter, forKey: "htmlDetectFrontMatter")
            renderRevision += 1
        }
    }

    var htmlTaskList: Bool = true {
        didSet { defaults.set(htmlTaskList, forKey: "htmlTaskList")
            renderRevision += 1
        }
    }

    var htmlHardWrap: Bool = false {
        didSet { defaults.set(htmlHardWrap, forKey: "htmlHardWrap")
            renderRevision += 1
        }
    }

    var htmlMathJax: Bool = false {
        didSet { defaults.set(htmlMathJax, forKey: "htmlMathJax")
            renderRevision += 1
        }
    }

    var htmlMathJaxInlineDollar: Bool = false {
        didSet { defaults.set(htmlMathJaxInlineDollar, forKey: "htmlMathJaxInlineDollar")
            renderRevision += 1
        }
    }

    var htmlSyntaxHighlighting: Bool = true {
        didSet { defaults.set(htmlSyntaxHighlighting, forKey: "htmlSyntaxHighlighting")
            renderRevision += 1
        }
    }

    /// A highlighting theme *family* name (e.g. `"github"`), never an exact light/dark filename --
    /// mirrors `htmlStyleName`'s own family convention (issue #100). Light/dark polarity is never
    /// set here; it's inherited from whichever of `previewAppearanceMode`/`printAppearanceMode`
    /// applies to the render path, via `HTMLComposer.resolveEffectiveHighlightThemeName`, the same
    /// way Mermaid already inherits its polarity rather than getting its own Appearance control.
    /// `loadHTMLDefaults` normalizes any pre-#100 persisted value (which could be a dark-suffixed
    /// filename like `"github-dark"`) to its family name on load.
    var htmlHighlightingThemeName: String = "github" {
        didSet { defaults.set(htmlHighlightingThemeName, forKey: "htmlHighlightingThemeName")
            renderRevision += 1
        }
    }

    var htmlLineNumbers: Bool = false {
        didSet { defaults.set(htmlLineNumbers, forKey: "htmlLineNumbers")
            renderRevision += 1
        }
    }

    var htmlCopyButton: Bool = true {
        didSet { defaults.set(htmlCopyButton, forKey: "htmlCopyButton")
            renderRevision += 1
        }
    }

    var htmlMermaid: Bool = false {
        didSet { defaults.set(htmlMermaid, forKey: "htmlMermaid")
            renderRevision += 1
        }
    }

    var htmlRendersTOC: Bool = false {
        didSet { defaults.set(htmlRendersTOC, forKey: "htmlRendersTOC")
            renderRevision += 1
        }
    }

    // MARK: - Private

    private let defaults: UserDefaults

    /// Stored property tracked by @Observable; incremented by every render-affecting setter
    /// so SplitEditorView can watch a single value instead of every individual preference.
    var renderRevision: Int = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Load persisted values. didSet is NOT called for direct property assignments
        // within the class's own init, so no side effects (no UserDefaults writes, no
        // renderRevision increments) occur here.
        loadExtensionDefaults(from: defaults)
        loadEditorDefaults(from: defaults)
        loadHTMLDefaults(from: defaults)
    }

    private func loadExtensionDefaults(from defaults: UserDefaults) {
        extensionTables = defaults.object(forKey: "extensionTables") != nil
            ? defaults.bool(forKey: "extensionTables") : true
        extensionAutolink = defaults.object(forKey: "extensionAutolink") != nil
            ? defaults.bool(forKey: "extensionAutolink") : true
        extensionStrikethrough = defaults.object(forKey: "extensionStrikethrough") != nil
            ? defaults.bool(forKey: "extensionStrikethrough") : true
        extensionHighlight = defaults.bool(forKey: "extensionHighlight")
        extensionFootnotes = defaults.object(forKey: "extensionFootnotes") != nil
            ? defaults.bool(forKey: "extensionFootnotes") : true
        extensionAlerts = defaults.object(forKey: "extensionAlerts") != nil
            ? defaults.bool(forKey: "extensionAlerts") : true
        extensionSmartyPants = defaults.bool(forKey: "extensionSmartyPants")
        markdownManualRender = defaults.bool(forKey: "markdownManualRender")
    }

    private func loadEditorDefaults(from defaults: UserDefaults) {
        editorFontName = defaults.string(forKey: "editorFontName") ?? "Menlo-Regular"
        let storedFontSize = defaults.double(forKey: "editorFontSize")
        fontSize = storedFontSize > 0 ? storedFontSize : Self.defaultFontSize
        editorAutoIncrementNumberedLists = defaults.object(forKey: "editorAutoIncrementNumberedLists") != nil
            ? defaults.bool(forKey: "editorAutoIncrementNumberedLists") : true
        editorConvertTabs = defaults.object(forKey: "editorConvertTabs") != nil
            ? defaults.bool(forKey: "editorConvertTabs") : true
        editorInsertPrefixInBlock = defaults.object(forKey: "editorInsertPrefixInBlock") != nil
            ? defaults.bool(forKey: "editorInsertPrefixInBlock") : true
        editorCompleteMatchingCharacters = defaults.object(forKey: "editorCompleteMatchingCharacters") != nil
            ? defaults.bool(forKey: "editorCompleteMatchingCharacters") : true
        editorSyncScrolling = defaults.object(forKey: "editorSyncScrolling") != nil
            ? defaults.bool(forKey: "editorSyncScrolling") : true
        editorSmartHome = defaults.object(forKey: "editorSmartHome") != nil
            ? defaults.bool(forKey: "editorSmartHome") : true
        editorStyleName = defaults.string(forKey: "editorStyleName") ?? "xcode"
        let hInset = defaults.double(forKey: "editorHorizontalInset")
        editorHorizontalInset = hInset > 0 ? hInset : 15
        let vInset = defaults.double(forKey: "editorVerticalInset")
        editorVerticalInset = vInset > 0 ? vInset : 30
        let lineSpacing = defaults.double(forKey: "editorLineSpacing")
        editorLineSpacing = lineSpacing > 0 ? lineSpacing : 3
        editorWidthLimited = defaults.bool(forKey: "editorWidthLimited")
        let maxWidth = defaults.double(forKey: "editorMaximumWidth")
        editorMaximumWidth = maxWidth > 0 ? maxWidth : 800
        editorOnRight = defaults.bool(forKey: "editorOnRight")
        editorShowWordCount = defaults.bool(forKey: "editorShowWordCount")
        editorScrollsPastEnd = defaults.object(forKey: "editorScrollsPastEnd") != nil
            ? defaults.bool(forKey: "editorScrollsPastEnd") : true
        editorEnsuresNewlineAtEndOfFile = defaults.object(forKey: "editorEnsuresNewlineAtEndOfFile") != nil
            ? defaults.bool(forKey: "editorEnsuresNewlineAtEndOfFile") : true
    }

    private func loadHTMLDefaults(from defaults: UserDefaults) {
        // Normalizes a pre-#96 persisted filename (e.g. "GitHub2 Dark") to its family name --
        // htmlStyleName/printStyleName only ever hold family names from here on.
        htmlStyleName = HTMLComposer.familyName(
            forFileName: defaults.string(forKey: "htmlStyleName") ?? "GitHub2"
        )
        printStyleName = defaults.string(forKey: "printStyleName").map(HTMLComposer.familyName(forFileName:))
        previewAppearanceMode = defaults.string(forKey: "previewAppearanceMode")
            .flatMap(PreviewAppearanceMode.init(rawValue:)) ?? .system
        printAppearanceMode = defaults.string(forKey: "printAppearanceMode")
            .flatMap(PreviewAppearanceMode.init(rawValue:))
        customCSSEnabled = defaults.bool(forKey: "customCSSEnabled")
        customCSS = defaults.string(forKey: "customCSS") ?? ""
        htmlDetectFrontMatter = defaults.object(forKey: "htmlDetectFrontMatter") != nil
            ? defaults.bool(forKey: "htmlDetectFrontMatter") : true
        htmlTaskList = defaults.object(forKey: "htmlTaskList") != nil
            ? defaults.bool(forKey: "htmlTaskList") : true
        htmlHardWrap = defaults.bool(forKey: "htmlHardWrap")
        htmlMathJax = defaults.bool(forKey: "htmlMathJax")
        htmlMathJaxInlineDollar = defaults.bool(forKey: "htmlMathJaxInlineDollar")
        htmlSyntaxHighlighting = defaults.object(forKey: "htmlSyntaxHighlighting") != nil
            ? defaults.bool(forKey: "htmlSyntaxHighlighting") : true
        htmlHighlightingThemeName = HTMLComposer.highlightFamilyName(
            forFileName: defaults.string(forKey: "htmlHighlightingThemeName") ?? "github"
        )
        htmlLineNumbers = defaults.bool(forKey: "htmlLineNumbers")
        htmlCopyButton = defaults.object(forKey: "htmlCopyButton") != nil
            ? defaults.bool(forKey: "htmlCopyButton") : true
        htmlMermaid = defaults.bool(forKey: "htmlMermaid")
        htmlRendersTOC = defaults.bool(forKey: "htmlRendersTOC")
    }
}
