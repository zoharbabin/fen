@testable import FenCore
import Foundation
import Testing

@Suite("Preferences Tests")
struct PreferencesTests {
    /// Each test gets a fresh isolated UserDefaults suite so tests cannot
    /// contaminate each other or the app's real UserDefaults.
    private static func isolated() -> (Preferences, UserDefaults) {
        let suiteName = "test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        return (Preferences(defaults: ud), ud)
    }

    @Test("Default values are correct")
    func defaults() {
        let (prefs, _) = Self.isolated()
        #expect(prefs.editorFontName == "Menlo-Regular")
        #expect(prefs.fontSize == 14)
        #expect(prefs.editorStyleName == "xcode")
        #expect(prefs.htmlStyleName == "GitHub2")
        #expect(prefs.extensionTables == true)
        #expect(prefs.extensionAutolink == true)
        #expect(prefs.extensionStrikethrough == true)
        #expect(prefs.htmlSyntaxHighlighting == true)
        #expect(prefs.htmlDetectFrontMatter == true)
        #expect(prefs.htmlTaskList == true)
    }

    @Test("Stored properties immediately reflect assigned values")
    func storedPropertyReflectsAssignment() {
        // Regression: when properties were computed (delegating to UserDefaults),
        // @Observable could not track changes — pickers reverted after selection.
        let (prefs, _) = Self.isolated()

        prefs.htmlStyleName = "GitHub2 Dark"
        #expect(prefs.htmlStyleName == "GitHub2 Dark")

        prefs.htmlStyleName = "Clearness"
        #expect(prefs.htmlStyleName == "Clearness")
    }

    @Test("renderRevision increments on render-affecting changes")
    func renderRevisionIncrements() {
        // Regression: settings only took effect after app restart because
        // SplitEditorView had no way to observe preference changes.
        // renderRevision is the stored @Observable sentinel it watches.
        let (prefs, _) = Self.isolated()
        let base = prefs.renderRevision

        prefs.htmlStyleName = "Clearness Dark"
        #expect(prefs.renderRevision == base + 1)

        prefs.htmlSyntaxHighlighting.toggle()
        #expect(prefs.renderRevision == base + 2)

        prefs.extensionTables.toggle()
        #expect(prefs.renderRevision == base + 3)

        prefs.extensionStrikethrough.toggle()
        #expect(prefs.renderRevision == base + 4)

        prefs.extensionAutolink.toggle()
        #expect(prefs.renderRevision == base + 5)

        prefs.htmlMathJax.toggle()
        #expect(prefs.renderRevision == base + 6)

        prefs.htmlMermaid.toggle()
        #expect(prefs.renderRevision == base + 7)

        prefs.htmlTaskList.toggle()
        #expect(prefs.renderRevision == base + 8)

        prefs.htmlHardWrap.toggle()
        #expect(prefs.renderRevision == base + 9)

        prefs.htmlRendersTOC.toggle()
        #expect(prefs.renderRevision == base + 10)

        prefs.htmlDetectFrontMatter.toggle()
        #expect(prefs.renderRevision == base + 11)

        prefs.extensionSmartyPants.toggle()
        #expect(prefs.renderRevision == base + 12)

        prefs.htmlHighlightingThemeName = "github-dark"
        #expect(prefs.renderRevision == base + 13)

        prefs.htmlLineNumbers.toggle()
        #expect(prefs.renderRevision == base + 14)

        prefs.htmlMathJaxInlineDollar.toggle()
        #expect(prefs.renderRevision == base + 15)
    }

    @Test("renderRevision does not increment for editor-only changes or fontSize")
    func renderRevisionStableForEditorPrefs() {
        let (prefs, _) = Self.isolated()
        let base = prefs.renderRevision

        prefs.editorStyleName = "github-dark"
        prefs.editorScrollsPastEnd.toggle()
        prefs.editorShowWordCount.toggle()
        prefs.editorConvertTabs.toggle()
        // fontSize is applied to the preview live via a CSS custom property (see
        // PreviewWebView.applyFontSize), not by recomposing/reloading, so it must not
        // bump renderRevision -- that would cause the exact reload-flash this avoids.
        prefs.fontSize += 1
        #expect(prefs.renderRevision == base)
    }

    @Test("increaseFontSize/decreaseFontSize/resetFontSize clamp and reset correctly")
    func fontSizeZoomControls() {
        let (prefs, _) = Self.isolated()

        prefs.fontSize = Preferences.maxFontSize
        prefs.increaseFontSize()
        #expect(prefs.fontSize == Preferences.maxFontSize)

        prefs.fontSize = Preferences.minFontSize
        prefs.decreaseFontSize()
        #expect(prefs.fontSize == Preferences.minFontSize)

        prefs.fontSize = 30
        prefs.resetFontSize()
        #expect(prefs.fontSize == Preferences.defaultFontSize)
    }
}
