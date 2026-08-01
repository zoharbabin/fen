@testable import FenCore
import Foundation
import Testing

/// Proves issue #118 rule 2.4: if `HTMLSanitizer.sanitize(_:)`'s hidden `WKWebView` load or
/// `evaluateJavaScript` call ever fails (e.g. WebKit resource pressure under a large parallel
/// test run -- reproduced by this exact codebase's full `swift test` suite before this fix),
/// the sanitizer must fail closed: escape the dirty HTML as inert text, never return it
/// unchanged as executable markup. `escapeAsPlainText` is the isolated, directly-testable unit
/// of that guarantee (see `HTMLSanitizer.sanitize(_:)`'s doc comment for why the full failure
/// path itself can't be reliably forced from a test).
struct SanitizerFailClosedTests {
    @Test
    func aScriptTagIsEscapedRatherThanReturnedAsMarkup() {
        let escaped = HTMLSanitizer.escapeAsPlainText("<script>alert('unsanitized')</script>")
        #expect(!escaped.contains("<script>"), "a failed sanitize pass must never let a literal <script> tag survive")
        #expect(
            escaped.contains("&lt;script&gt;"),
            "the tag must be escaped to inert text, not dropped or left ambiguous"
        )
    }

    @Test
    func anEventHandlerAttributeIsEscapedRatherThanReturnedAsMarkup() {
        let escaped = HTMLSanitizer.escapeAsPlainText(#"<div onclick="alert(1)">text</div>"#)
        #expect(
            !escaped.contains("<div"),
            "a failed sanitize pass must never let a literal element with an event handler survive as markup"
        )
    }

    @Test
    func ampersandsAreEscapedFirstSoTheOutputNeverDoubleUnescapes() {
        let escaped = HTMLSanitizer.escapeAsPlainText("a && b < c")
        #expect(escaped == "a &amp;&amp; b &lt; c", "escaping order must not corrupt already-escaped ampersands")
    }
}
