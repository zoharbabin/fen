import Foundation
import SwiftUI

@Observable
public final class Preferences {
    public nonisolated(unsafe) static let shared = Preferences()

    // MARK: - General

    var suppressesUntitledDocumentOnLaunch: Bool = false {
        didSet { defaults.set(suppressesUntitledDocumentOnLaunch, forKey: "suppressesUntitledDocumentOnLaunch") }
    }

    var createFileForLinkTarget: Bool = false {
        didSet { defaults.set(createFileForLinkTarget, forKey: "createFileForLinkTarget") }
    }

    // MARK: - Markdown Extension Flags

    var extensionIntraEmphasis: Bool = false {
        didSet { defaults.set(extensionIntraEmphasis, forKey: "extensionIntraEmphasis") }
    }

    var extensionTables: Bool = true {
        didSet { defaults.set(extensionTables, forKey: "extensionTables")
            renderRevision += 1
        }
    }

    var extensionFencedCode: Bool = true {
        didSet { defaults.set(extensionFencedCode, forKey: "extensionFencedCode")
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

    var extensionUnderline: Bool = false {
        didSet { defaults.set(extensionUnderline, forKey: "extensionUnderline") }
    }

    var extensionSuperscript: Bool = false {
        didSet { defaults.set(extensionSuperscript, forKey: "extensionSuperscript") }
    }

    var extensionHighlight: Bool = false {
        didSet { defaults.set(extensionHighlight, forKey: "extensionHighlight") }
    }

    var extensionFootnotes: Bool = false {
        didSet { defaults.set(extensionFootnotes, forKey: "extensionFootnotes") }
    }

    var extensionQuote: Bool = false {
        didSet { defaults.set(extensionQuote, forKey: "extensionQuote") }
    }

    var extensionSmartyPants: Bool = false {
        didSet { defaults.set(extensionSmartyPants, forKey: "extensionSmartyPants")
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

    var editorFontSize: CGFloat = 14 {
        didSet { defaults.set(Double(editorFontSize), forKey: "editorFontSize") }
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

    var htmlStyleName: String = "GitHub2" {
        didSet { defaults.set(htmlStyleName, forKey: "htmlStyleName")
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
        loadGeneralDefaults(from: defaults)
        loadExtensionDefaults(from: defaults)
        loadEditorDefaults(from: defaults)
        loadHTMLDefaults(from: defaults)
    }

    private func loadGeneralDefaults(from defaults: UserDefaults) {
        suppressesUntitledDocumentOnLaunch = defaults.bool(forKey: "suppressesUntitledDocumentOnLaunch")
        createFileForLinkTarget = defaults.bool(forKey: "createFileForLinkTarget")
    }

    private func loadExtensionDefaults(from defaults: UserDefaults) {
        extensionIntraEmphasis = defaults.bool(forKey: "extensionIntraEmphasis")
        extensionTables = defaults.object(forKey: "extensionTables") != nil
            ? defaults.bool(forKey: "extensionTables") : true
        extensionFencedCode = defaults.object(forKey: "extensionFencedCode") != nil
            ? defaults.bool(forKey: "extensionFencedCode") : true
        extensionAutolink = defaults.object(forKey: "extensionAutolink") != nil
            ? defaults.bool(forKey: "extensionAutolink") : true
        extensionStrikethrough = defaults.object(forKey: "extensionStrikethrough") != nil
            ? defaults.bool(forKey: "extensionStrikethrough") : true
        extensionUnderline = defaults.bool(forKey: "extensionUnderline")
        extensionSuperscript = defaults.bool(forKey: "extensionSuperscript")
        extensionHighlight = defaults.bool(forKey: "extensionHighlight")
        extensionFootnotes = defaults.bool(forKey: "extensionFootnotes")
        extensionQuote = defaults.bool(forKey: "extensionQuote")
        extensionSmartyPants = defaults.bool(forKey: "extensionSmartyPants")
        markdownManualRender = defaults.bool(forKey: "markdownManualRender")
    }

    private func loadEditorDefaults(from defaults: UserDefaults) {
        editorFontName = defaults.string(forKey: "editorFontName") ?? "Menlo-Regular"
        let fontSize = defaults.double(forKey: "editorFontSize")
        editorFontSize = fontSize > 0 ? fontSize : 14
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
        htmlStyleName = defaults.string(forKey: "htmlStyleName") ?? "GitHub2"
        htmlDetectFrontMatter = defaults.object(forKey: "htmlDetectFrontMatter") != nil
            ? defaults.bool(forKey: "htmlDetectFrontMatter") : true
        htmlTaskList = defaults.object(forKey: "htmlTaskList") != nil
            ? defaults.bool(forKey: "htmlTaskList") : true
        htmlHardWrap = defaults.bool(forKey: "htmlHardWrap")
        htmlMathJax = defaults.bool(forKey: "htmlMathJax")
        htmlMathJaxInlineDollar = defaults.bool(forKey: "htmlMathJaxInlineDollar")
        htmlSyntaxHighlighting = defaults.object(forKey: "htmlSyntaxHighlighting") != nil
            ? defaults.bool(forKey: "htmlSyntaxHighlighting") : true
        htmlHighlightingThemeName = defaults.string(forKey: "htmlHighlightingThemeName") ?? "github"
        htmlLineNumbers = defaults.bool(forKey: "htmlLineNumbers")
        htmlMermaid = defaults.bool(forKey: "htmlMermaid")
        htmlRendersTOC = defaults.bool(forKey: "htmlRendersTOC")
    }
}
