@testable import FenCore
import Foundation
import Testing

/// Proves issue #118 rule 4.1 under its corrected architecture (see the issue's "Phase 1 --
/// architecture correction" comment): `HTMLComposer.swift` is unchanged, and the vendored
/// `purify.min.js` loads only inside `HTMLSanitizer`'s own hidden `WKWebView`, created lazily on
/// first use -- never eagerly at construction, and never for a caller that skips `sanitize(_:)`
/// entirely via `HTMLSanitizer.mayContainRawHTML(_:)`'s fast path.
struct SanitizerLazyLoadVerifyTest {
    @Test @MainActor
    func constructingASanitizerNeverLoadsTheHiddenWebView() {
        let sanitizer = HTMLSanitizer()
        #expect(
            !sanitizer.hasCreatedWebView,
            "HTMLSanitizer() must not create its hidden WKWebView until sanitize(_:) is first called"
        )
    }

    @Test @MainActor
    func firstSanitizeCallCreatesTheHiddenWebViewOnDemand() async {
        let sanitizer = HTMLSanitizer()
        #expect(!sanitizer.hasCreatedWebView)

        _ = await sanitizer.sanitize("<kbd>x</kbd>")

        #expect(sanitizer.hasCreatedWebView, "the first sanitize(_:) call must have created the hidden WKWebView")
    }
}
