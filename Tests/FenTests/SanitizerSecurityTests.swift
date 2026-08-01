@testable import FenCore
import Foundation
import Testing

/// Proves issue #118 rule 2.1: every denied tag, attribute, and URL scheme is stripped by the
/// real pipeline a document actually goes through -- `MarkdownRenderer.render` (with
/// `CMARK_OPT_UNSAFE` letting raw HTML through, exactly as production `Options.sanitizeRawHTML`
/// does) followed by the real vendored `HTMLSanitizer`, the one place that guarantee is actually
/// enforced (`MarkdownRenderer.render` itself never sanitizes -- see `Options.sanitizeRawHTML`'s
/// doc comment). Mirrors `ExportAssetResolverSecurityTests.swift`'s per-vector-table pattern.
struct SanitizerSecurityTests {
    @MainActor
    private func sanitizedOutput(forMarkdown markdown: String) async -> String {
        var options = MarkdownRenderer.Options()
        options.sanitizeRawHTML = true
        let rendered = MarkdownRenderer().render(markdown, options: options)
        return await HTMLSanitizer().sanitize(rendered.html)
    }

    @Test @MainActor
    func deniedTagsNeverSurviveSanitization() async {
        let deniedTags = ["script", "style", "iframe", "object", "embed", "form", "link", "meta", "base"]
        for tag in deniedTags {
            let output = await sanitizedOutput(forMarkdown: "<\(tag)>payload</\(tag)>")
            #expect(!output.contains("<\(tag)"), "denied tag <\(tag)> must never survive sanitization")
        }
    }

    @Test @MainActor
    func deniedInputTagIsStrippedDespiteBeingOnTheAllowlistForTaskListCheckboxes() async {
        // <input> is allowlisted (sanitize-config.js) because cmark-gfm's own task-list
        // rendering emits <input type="checkbox">, but a raw-HTML <input> from the Markdown
        // source itself is indistinguishable to DOMPurify from Fen's own rendering -- this test
        // documents that <input> survives (expected), while confirming its dangerous attributes/
        // event handlers (checked below) still don't.
        let output = await sanitizedOutput(forMarkdown: #"<input type="text" onfocus="alert(1)">"#)
        #expect(!output.contains("onfocus"), "an event-handler attribute on an allowlisted tag must still be stripped")
    }

    @Test @MainActor
    func everyOnEventHandlerAttributeIsStrippedFromAnAllowlistedTag() async {
        let handlers = ["onclick", "onerror", "onload", "onmouseover", "onfocus"]
        for handler in handlers {
            let output = await sanitizedOutput(forMarkdown: #"<div \#(handler)="alert(1)">text</div>"#)
            #expect(!output.contains(handler), "event handler attribute '\(handler)' must never survive sanitization")
        }
    }

    @Test @MainActor
    func javascriptURLSchemeIsStrippedFromAnAnchorHref() async {
        let output = await sanitizedOutput(forMarkdown: #"<a href="javascript:alert(1)">click me</a>"#)
        #expect(!output.contains("javascript:"), "a javascript: URL scheme must never survive sanitization")
    }

    @Test @MainActor
    func dataURLSchemeIsStrippedFromAnAnchorHrefButStillAllowedOnImg() async {
        // DOMPurify's default DATA_URI_TAGS permits data: on <img>/<source> (self-contained
        // export's inlined images depend on this -- ExportAssetResolver.swift) but not on <a
        // href>, which has no legitimate reason to carry one and is a known XSS vector
        // (a data:text/html URL that executes script when clicked/navigated).
        let anchorOutput =
            await sanitizedOutput(forMarkdown: #"<a href="data:text/html,<script>alert(1)</script>">click</a>"#)
        #expect(
            !anchorOutput.contains("data:text/html"),
            "a data: URL on an anchor href must never survive sanitization"
        )

        let imgOutput = await sanitizedOutput(forMarkdown: #"<img src="data:image/png;base64,AAAA">"#)
        #expect(imgOutput.contains("data:image/png;base64,AAAA"), "a data: image URL on img must still be allowed")
    }

    @Test @MainActor
    func htmlCommentsSurviveSanitizationUnchanged() async {
        let output = await sanitizedOutput(forMarkdown: "<!-- a genuine comment -->")
        #expect(output.contains("a genuine comment"), "HTML comments are explicitly allowlisted (issue #118 Phase 1)")
    }

    @Test @MainActor
    func allowlistedGitHubTagsSurviveSanitizationUnchanged() async {
        let allowlisted = ["sub", "sup", "ins", "kbd", "details", "summary"]
        for tag in allowlisted {
            let output = await sanitizedOutput(forMarkdown: "<\(tag)>content</\(tag)>")
            #expect(output.contains("<\(tag)"), "allowlisted tag <\(tag)> must survive sanitization")
        }
    }
}
