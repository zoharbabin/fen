@testable import FenCore
import Foundation
import Testing

/// Proves rule 2.2 from issue #1's spec: adversarial filter text (script-injection payloads,
/// shell metacharacters) is compared and spliced as inert literal text -- never interpolated
/// into a JS/HTML/shell sink -- mirrors `MarkdownFormattingSecurityTests`'s pattern.
struct SlashCommandMenuSecurityTests {
    @Test func adversarialFilterTextNeverMatchesAndStaysInert() {
        let scriptPayload = "</script><script>alert(1)</script>"
        let shellPayload = "$(rm -rf /); `echo pwned`"

        for payload in [scriptPayload, shellPayload] {
            // Neither payload happens to match any of the 7 fixed block-type names, so
            // filtering degrades to an empty list rather than doing anything with the payload.
            #expect(SlashCommandMenu.filteredEntries(query: payload).isEmpty)
        }

        // The payload's own embedded "/" characters (inside `</script>`) are each preceded by
        // "<", never whitespace or line-start -- so the backward scan correctly finds no valid
        // trigger and returns nil, rather than mis-tokenizing the payload as filter text.
        let text = "/\(scriptPayload)"
        let match = SlashCommandMenu.triggerMatch(text: text, cursorLocation: (text as NSString).length)
        #expect(match == nil)
    }

    @Test func adversarialFilterTextIsSplicedAsInertLiteralWhenCommitted() {
        let scriptPayload = "</script><script>alert(1)</script>"
        let text = "\(scriptPayload) after"
        let selection = NSRange(location: 0, length: 0)

        // Simulates the initial content of a heading committed via the slash menu -- the
        // payload passes through MarkdownFormatting.apply's plain NSString splice exactly like
        // every other FormattingAction, never through an evaluateJavaScript/HTML/shell sink.
        let result = MarkdownFormatting.apply(.heading1, to: text, selection: selection)
        // The payload survives verbatim, as plain text -- proving it was spliced once as a
        // literal string rather than parsed, executed, or duplicated by any escaping logic.
        #expect(result.text == "# \(scriptPayload) after")
    }
}
