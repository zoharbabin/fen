@testable import FenCore
import Foundation
import Testing

/// Proves rule 2.1 from issue #13's spec: `MarkdownFormatting.apply` only splices characters --
/// it never evaluates selected/inserted text as code, so a selection containing script-breakout
/// or shell-metacharacter text passes through as inert literal data.
struct MarkdownFormattingSecurityTests {
    @Test func selectionContainingScriptBreakoutTextIsSplicedAsInertLiteralText() {
        let malicious = "</script><script>alert(1)</script>"
        let text = "before \(malicious) after"
        let selection = (text as NSString).range(of: malicious)
        let result = MarkdownFormatting.apply(.bold, to: text, selection: selection)
        #expect(result.text == "before **\(malicious)** after")
    }

    @Test func selectionContainingShellMetacharactersIsSplicedAsInertLiteralText() {
        let malicious = "$(rm -rf /); `echo pwned`"
        let text = "cmd: \(malicious)"
        let selection = (text as NSString).range(of: malicious)
        let result = MarkdownFormatting.apply(.inlineCode, to: text, selection: selection)
        #expect(result.text == "cmd: `\(malicious)`")
    }
}
