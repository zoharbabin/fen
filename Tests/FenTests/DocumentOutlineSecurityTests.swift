@testable import FenCore
import Foundation
import Testing

/// Proves rule 2.1 from issue #12's spec: heading titles never reach a JS/HTML
/// evaluation context unsanitized -- the outline is pure SwiftUI `Text` + a
/// slug-based jump target, not a raw-text injection into any script or markup string.
struct DocumentOutlineSecurityTests {
    @Test func headingWithScriptBreakoutTextStaysAsPlainTextNeverEvaluated() {
        let renderer = MarkdownRenderer()
        let malicious = "</script><script>alert(1)</script>"
        let result = renderer.render("# \(malicious)")

        guard let heading = result.headings.first else {
            Issue.record("Expected one heading to be extracted")
            return
        }

        // The heading's displayable text has already had every tag stripped by the same
        // plain-text extraction TOC generation uses -- no raw "<"/">" survives, so there's no
        // markup fragment left that a later evaluateJavaScript/HTML interpolation could
        // reinterpret as a tag.
        #expect(!heading.text.contains("<"))
        #expect(!heading.text.contains(">"))
        #expect(!heading.slug.contains("<"))
        #expect(!heading.slug.contains(">"))
        #expect(!heading.slug.contains("\""))
        #expect(!heading.slug.contains("'"))
    }

    @Test func headingWithQuoteAndBacktickBreakoutCharactersProducesSafeSlug() {
        let renderer = MarkdownRenderer()
        let result = renderer.render(#"# `code`" + '; window.location="evil""#)

        guard let heading = result.headings.first else {
            Issue.record("Expected one heading to be extracted")
            return
        }

        // Slugs are the only heading-derived value used to build a jump target (an anchor
        // href / accessibility identifier) -- they must be restricted to a safe character
        // set regardless of what punctuation the source heading text contains.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        #expect(heading.slug.unicodeScalars.allSatisfy { allowed.contains($0) })
    }
}
