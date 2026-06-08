import Foundation
import SwiftUI

@Observable
public final class Preferences {
    nonisolated(unsafe) public static let shared = Preferences()

    // MARK: - General

    var suppressesUntitledDocumentOnLaunch: Bool {
        get { defaults.bool(forKey: "suppressesUntitledDocumentOnLaunch") }
        set { defaults.set(newValue, forKey: "suppressesUntitledDocumentOnLaunch") }
    }

    var createFileForLinkTarget: Bool {
        get { defaults.bool(forKey: "createFileForLinkTarget") }
        set { defaults.set(newValue, forKey: "createFileForLinkTarget") }
    }

    // MARK: - Markdown Extension Flags

    var extensionIntraEmphasis: Bool {
        get { defaults.bool(forKey: "extensionIntraEmphasis") }
        set { defaults.set(newValue, forKey: "extensionIntraEmphasis") }
    }

    var extensionTables: Bool {
        get { defaults.boolWithDefault(forKey: "extensionTables", default: true) }
        set { defaults.set(newValue, forKey: "extensionTables") }
    }

    var extensionFencedCode: Bool {
        get { defaults.boolWithDefault(forKey: "extensionFencedCode", default: true) }
        set { defaults.set(newValue, forKey: "extensionFencedCode") }
    }

    var extensionAutolink: Bool {
        get { defaults.boolWithDefault(forKey: "extensionAutolink", default: true) }
        set { defaults.set(newValue, forKey: "extensionAutolink") }
    }

    var extensionStrikethrough: Bool {
        get { defaults.boolWithDefault(forKey: "extensionStrikethrough", default: true) }
        set { defaults.set(newValue, forKey: "extensionStrikethrough") }
    }

    var extensionUnderline: Bool {
        get { defaults.bool(forKey: "extensionUnderline") }
        set { defaults.set(newValue, forKey: "extensionUnderline") }
    }

    var extensionSuperscript: Bool {
        get { defaults.bool(forKey: "extensionSuperscript") }
        set { defaults.set(newValue, forKey: "extensionSuperscript") }
    }

    var extensionHighlight: Bool {
        get { defaults.bool(forKey: "extensionHighlight") }
        set { defaults.set(newValue, forKey: "extensionHighlight") }
    }

    var extensionFootnotes: Bool {
        get { defaults.bool(forKey: "extensionFootnotes") }
        set { defaults.set(newValue, forKey: "extensionFootnotes") }
    }

    var extensionQuote: Bool {
        get { defaults.bool(forKey: "extensionQuote") }
        set { defaults.set(newValue, forKey: "extensionQuote") }
    }

    var extensionSmartyPants: Bool {
        get { defaults.bool(forKey: "extensionSmartyPants") }
        set { defaults.set(newValue, forKey: "extensionSmartyPants") }
    }

    var markdownManualRender: Bool {
        get { defaults.bool(forKey: "markdownManualRender") }
        set { defaults.set(newValue, forKey: "markdownManualRender") }
    }

    // MARK: - Editor

    var editorFontName: String {
        get { defaults.string(forKey: "editorFontName") ?? "Menlo-Regular" }
        set { defaults.set(newValue, forKey: "editorFontName") }
    }

    var editorFontSize: CGFloat {
        get {
            let val = defaults.double(forKey: "editorFontSize")
            return val > 0 ? val : 14
        }
        set { defaults.set(newValue, forKey: "editorFontSize") }
    }

    var editorAutoIncrementNumberedLists: Bool {
        get { defaults.boolWithDefault(forKey: "editorAutoIncrementNumberedLists", default: true) }
        set { defaults.set(newValue, forKey: "editorAutoIncrementNumberedLists") }
    }

    var editorConvertTabs: Bool {
        get { defaults.boolWithDefault(forKey: "editorConvertTabs", default: true) }
        set { defaults.set(newValue, forKey: "editorConvertTabs") }
    }

    var editorInsertPrefixInBlock: Bool {
        get { defaults.boolWithDefault(forKey: "editorInsertPrefixInBlock", default: true) }
        set { defaults.set(newValue, forKey: "editorInsertPrefixInBlock") }
    }

    var editorCompleteMatchingCharacters: Bool {
        get { defaults.boolWithDefault(forKey: "editorCompleteMatchingCharacters", default: true) }
        set { defaults.set(newValue, forKey: "editorCompleteMatchingCharacters") }
    }

    var editorSyncScrolling: Bool {
        get { defaults.boolWithDefault(forKey: "editorSyncScrolling", default: true) }
        set { defaults.set(newValue, forKey: "editorSyncScrolling") }
    }

    var editorSmartHome: Bool {
        get { defaults.boolWithDefault(forKey: "editorSmartHome", default: true) }
        set { defaults.set(newValue, forKey: "editorSmartHome") }
    }

    /// Highlightr (highlight.js) theme name used for editor syntax highlighting.
    /// Defaults to "xcode" — a light theme that pairs with the GitHub2 preview.
    var editorStyleName: String {
        get { defaults.string(forKey: "editorStyleName") ?? "xcode" }
        set { defaults.set(newValue, forKey: "editorStyleName") }
    }

    var editorHorizontalInset: CGFloat {
        get {
            let val = defaults.double(forKey: "editorHorizontalInset")
            return val > 0 ? val : 15
        }
        set { defaults.set(newValue, forKey: "editorHorizontalInset") }
    }

    var editorVerticalInset: CGFloat {
        get {
            let val = defaults.double(forKey: "editorVerticalInset")
            return val > 0 ? val : 30
        }
        set { defaults.set(newValue, forKey: "editorVerticalInset") }
    }

    var editorLineSpacing: CGFloat {
        get {
            let val = defaults.double(forKey: "editorLineSpacing")
            return val > 0 ? val : 3
        }
        set { defaults.set(newValue, forKey: "editorLineSpacing") }
    }

    var editorWidthLimited: Bool {
        get { defaults.bool(forKey: "editorWidthLimited") }
        set { defaults.set(newValue, forKey: "editorWidthLimited") }
    }

    var editorMaximumWidth: CGFloat {
        get {
            let val = defaults.double(forKey: "editorMaximumWidth")
            return val > 0 ? val : 800
        }
        set { defaults.set(newValue, forKey: "editorMaximumWidth") }
    }

    var editorOnRight: Bool {
        get { defaults.bool(forKey: "editorOnRight") }
        set { defaults.set(newValue, forKey: "editorOnRight") }
    }

    var editorShowWordCount: Bool {
        get { defaults.bool(forKey: "editorShowWordCount") }
        set { defaults.set(newValue, forKey: "editorShowWordCount") }
    }

    var editorScrollsPastEnd: Bool {
        get { defaults.boolWithDefault(forKey: "editorScrollsPastEnd", default: true) }
        set { defaults.set(newValue, forKey: "editorScrollsPastEnd") }
    }

    var editorEnsuresNewlineAtEndOfFile: Bool {
        get { defaults.boolWithDefault(forKey: "editorEnsuresNewlineAtEndOfFile", default: true) }
        set { defaults.set(newValue, forKey: "editorEnsuresNewlineAtEndOfFile") }
    }

    // MARK: - HTML / Preview

    var htmlStyleName: String {
        get { defaults.string(forKey: "htmlStyleName") ?? "GitHub2" }
        set { defaults.set(newValue, forKey: "htmlStyleName") }
    }

    var htmlDetectFrontMatter: Bool {
        get { defaults.boolWithDefault(forKey: "htmlDetectFrontMatter", default: true) }
        set { defaults.set(newValue, forKey: "htmlDetectFrontMatter") }
    }

    var htmlTaskList: Bool {
        get { defaults.boolWithDefault(forKey: "htmlTaskList", default: true) }
        set { defaults.set(newValue, forKey: "htmlTaskList") }
    }

    var htmlHardWrap: Bool {
        get { defaults.bool(forKey: "htmlHardWrap") }
        set { defaults.set(newValue, forKey: "htmlHardWrap") }
    }

    var htmlMathJax: Bool {
        get { defaults.bool(forKey: "htmlMathJax") }
        set { defaults.set(newValue, forKey: "htmlMathJax") }
    }

    var htmlMathJaxInlineDollar: Bool {
        get { defaults.bool(forKey: "htmlMathJaxInlineDollar") }
        set { defaults.set(newValue, forKey: "htmlMathJaxInlineDollar") }
    }

    var htmlSyntaxHighlighting: Bool {
        get { defaults.boolWithDefault(forKey: "htmlSyntaxHighlighting", default: true) }
        set { defaults.set(newValue, forKey: "htmlSyntaxHighlighting") }
    }

    var htmlHighlightingThemeName: String {
        get { defaults.string(forKey: "htmlHighlightingThemeName") ?? "prism" }
        set { defaults.set(newValue, forKey: "htmlHighlightingThemeName") }
    }

    var htmlLineNumbers: Bool {
        get { defaults.bool(forKey: "htmlLineNumbers") }
        set { defaults.set(newValue, forKey: "htmlLineNumbers") }
    }

    var htmlMermaid: Bool {
        get { defaults.bool(forKey: "htmlMermaid") }
        set { defaults.set(newValue, forKey: "htmlMermaid") }
    }

    var htmlRendersTOC: Bool {
        get { defaults.bool(forKey: "htmlRendersTOC") }
        set { defaults.set(newValue, forKey: "htmlRendersTOC") }
    }

    // MARK: - Private

    private let defaults = UserDefaults.standard

    public init() {}
}

// MARK: - UserDefaults Helper

private extension UserDefaults {
    func boolWithDefault(forKey key: String, default defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil { return defaultValue }
        return bool(forKey: key)
    }
}
