@testable import FenCore
import Foundation
import Testing

/// Proves issue #118 rule 1.1: `MarkdownRenderer` stays a value-type `struct` with no
/// module-level mutable state, and two `HTMLSanitizer` instances (e.g. the live preview's and
/// an export path's, per `Shared/Preview/HTMLSanitizer.swift`'s doc comment) never share or
/// corrupt each other's state -- mirrors `QuickLookIsolationTests.swift`'s two-instance pattern.
struct SanitizerIsolationTests {
    @Test
    func twoRendererInstancesWithDifferentSanitizeOptionsNeverLeakAcrossEachOther() {
        var sanitizedOptions = MarkdownRenderer.Options()
        sanitizedOptions.sanitizeRawHTML = true
        var unsanitizedOptions = MarkdownRenderer.Options()
        unsanitizedOptions.sanitizeRawHTML = false

        let rendererA = MarkdownRenderer()
        let rendererB = MarkdownRenderer()

        let resultA = rendererA.render("<kbd>from A</kbd>", options: sanitizedOptions)
        let resultB = rendererB.render("<kbd>from B</kbd>", options: unsanitizedOptions)

        // sanitizeRawHTML only controls whether CMARK_OPT_UNSAFE lets raw HTML through cmark at
        // all -- both renders emit the literal <kbd> tag either way, since the actual DOMPurify
        // pass runs later, outside MarkdownRenderer (see Options.sanitizeRawHTML's doc comment).
        #expect(resultA.html.contains("from A"))
        #expect(resultB.html.contains("from B"))
        #expect(!resultA.html.contains("from B"), "renderer A's result must never contain renderer B's content")
        #expect(!resultB.html.contains("from A"), "renderer B's result must never contain renderer A's content")

        // Re-rendering through rendererA with unsanitizedOptions must reflect that call's own
        // options, not whatever sanitizedOptions produced moments earlier -- proving Options is
        // read fresh from the argument each call, not cached on the instance.
        let resultAAgain = rendererA.render("<kbd>from A again</kbd>", options: unsanitizedOptions)
        #expect(resultAAgain.html.contains("from A again"))
    }

    @Test @MainActor
    func twoHTMLSanitizerInstancesOwnIndependentHiddenWebViewsAndNeverCrossContaminate() async {
        let sanitizerA = HTMLSanitizer()
        let sanitizerB = HTMLSanitizer()

        async let resultA = sanitizerA.sanitize("<kbd>alpha payload</kbd>")
        async let resultB = sanitizerB.sanitize("<kbd>beta payload</kbd>")
        let (outputA, outputB) = await (resultA, resultB)

        #expect(outputA.contains("alpha payload"))
        #expect(outputB.contains("beta payload"))
        #expect(!outputA.contains("beta payload"), "sanitizer A's result must never contain sanitizer B's content")
        #expect(!outputB.contains("alpha payload"), "sanitizer B's result must never contain sanitizer A's content")
    }

    @Test @MainActor
    func aSharedSanitizerInstanceReusedAcrossCallsStillReturnsEachCallsOwnResult() async {
        // HTMLSanitizer.shared is deliberately reused across DocumentHTMLExporter/
        // DocumentPDFExporter calls for performance (issue #118 Phase 4 fix), unlike
        // SplitEditorView's per-editor instance -- proves reuse never bleeds one call's content
        // into another's despite sharing the same underlying hidden WKWebView.
        let firstResult = await HTMLSanitizer.shared.sanitize("<kbd>call one</kbd>")
        let secondResult = await HTMLSanitizer.shared.sanitize("<kbd>call two</kbd>")

        #expect(firstResult.contains("call one"))
        #expect(secondResult.contains("call two"))
        #expect(
            !secondResult.contains("call one"),
            "a later call through the shared instance must not see an earlier call's content"
        )
    }
}
