@testable import FenCore
import Foundation
import Testing

/// Issue #250: `MarkdownRenderer` finds inline math in the source, before cmark strips backslashes and reads `_` and
/// `*` as emphasis, and hands MathJax only the formulas that follow the `$` rules.
@Suite("Inline math source pass")
struct InlineMathSourcePassTests {
    private func html(_ markdown: String, _ delimiters: LivePreviewEditing.MathDelimiters = [.parentheses, .dollars])
        -> String {
        var options = MarkdownRenderer.Options()
        options.inlineMath = delimiters
        return MarkdownRenderer().render(markdown, options: options).html
    }

    @Test("Two prices in a sentence stay text")
    func pricesStayText() {
        let out = html("Braze for $47.50 per share in cash, about $5.66B enterprise value.")
        #expect(out.contains("$47.50 per share in cash, about $5.66B"))
        #expect(!out.contains("\\("))
    }

    @Test("An escaped dollar sign stays a dollar sign")
    func escapedDollar() {
        let out = html("Costs \\$4 and \\$5 total, and $a$ is math.")
        #expect(out.contains("Costs $4 and $5 total"))
        #expect(out.contains("\\(a\\)"))
    }

    @Test("A dollar formula becomes MathJax's inline delimiter, TeX intact")
    func dollarFormula() {
        let out = html("Set $\\{a_1, *b*\\} < c$ here.")
        #expect(out.contains("\\(\\{a_1, *b*\\} &lt; c\\)"))
        #expect(!out.contains("<em>"))
    }

    @Test("A parenthesis formula keeps its backslashes")
    func parenthesisFormula() {
        #expect(html("Area is \\(x^2\\) here.").contains("Area is \\(x^2\\) here."))
    }

    @Test("Dollars are text when only parentheses are on")
    func dollarsOff() {
        let out = html("A $x$ and \\(y\\).", .parentheses)
        #expect(out.contains("A $x$ and \\(y\\)."))
    }

    @Test("Nothing changes when math is off")
    func mathOff() {
        let out = html("A $x_1$ and \\(y\\).", [])
        #expect(out.contains("A $x_1$ and (y)."))
    }

    @Test("Display math is left to MathJax")
    func displayMath() {
        #expect(html("Here $$z$$ now.").contains("Here $$z$$ now."))
    }

    @Test("Code stays literal", arguments: [
        "Use `$x$ and \\(y\\)` inline.",
        "```\n$x$ and \\(y\\)\n```",
        "~~~sh\n$x$ and \\(y\\)\n~~~",
        "Text\n\n    $x$ and \\(y\\)\n",
    ])
    func codeStaysLiteral(markdown: String) {
        let out = html(markdown)
        #expect(out.contains("$x$"))
        #expect(!out.contains("\\(x\\)"))
    }

    @Test("A formula in a list item continuation still renders")
    func listContinuation() {
        let out = html("- item\n\n    more $x$ text\n")
        #expect(out.contains("\\(x\\)"))
    }

    @Test("Formulas in text after a code span still render")
    func afterCodeSpan() {
        #expect(html("`code` then $x$").contains("<code>code</code> then \\(x\\)"))
    }

    @Test("The line count is unchanged")
    func lineCount() {
        let renderer = MarkdownRenderer()
        let source = "a $x$\n\n```\n$y$\n```\n\nb $z$\n"
        let hidden = renderer.hideInlineMath(in: source, delimiters: [.parentheses, .dollars])
        #expect(hidden.text.split(separator: "\n", omittingEmptySubsequences: false).count
            == source.split(separator: "\n", omittingEmptySubsequences: false).count)
        #expect(hidden.formulas == ["$x$", "$z$"])
    }

    @Test("Preferences choose the delimiters")
    func optionsFromPreferences() throws {
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: "math.\(UUID().uuidString)")))
        #expect(MarkdownRenderer.Options.from(preferences: prefs).inlineMath.isEmpty)
        prefs.htmlMathJax = true
        #expect(MarkdownRenderer.Options.from(preferences: prefs).inlineMath == .parentheses)
        prefs.htmlMathJaxInlineDollar = true
        #expect(MarkdownRenderer.Options.from(preferences: prefs).inlineMath == [.parentheses, .dollars])
    }
}
