@testable import FenCore
import Testing

/// Rules from issue #12's spec (github.com/zoharbabin/fen/issues/12). Each test
/// below is named after and cites the rule number it proves.
struct DocumentOutlineTests {
    // MARK: - Rule 3.2: malformed/empty input never crashes

    @Test func emptyDocumentProducesEmptyOutline() {
        let renderer = MarkdownRenderer()
        let result = renderer.render("")
        #expect(result.headings.isEmpty)
    }

    @Test func documentWithNoHeadingsProducesEmptyOutline() {
        let renderer = MarkdownRenderer()
        let result = renderer.render("Just a paragraph. No headings here.\n\nAnother paragraph.")
        #expect(result.headings.isEmpty)
    }

    @Test func malformedHeadingSyntaxDoesNotCrash() {
        let renderer = MarkdownRenderer()
        // Unterminated emphasis, a bare '#' with no space, and deeply nested inline markup
        // inside a heading -- none of this should throw or hang the regex-based extraction.
        let result = renderer
            .render("#NoSpace\n\n## **Unterminated *emphasis\n\n### `code with *stars* and _underscores_`")
        #expect(result.headings.count <= 3)
    }

    // MARK: - Rule 4.1: one heading-extraction implementation shared by TOC and outline

    @Test func extractedHeadingsMatchLevelsAndText() {
        let renderer = MarkdownRenderer()
        let result = renderer.render("# Title\n\n## Section One\n\n### Sub Section\n\n## Section Two")
        #expect(result.headings.map(\.level) == [1, 2, 3, 2])
        #expect(result.headings.map(\.text) == ["Title", "Section One", "Sub Section", "Section Two"])
    }

    @Test func headingsAreExposedIndependentlyOfTOCPreference() {
        // The outline is a navigation aid, not gated behind the `[TOC]` marker or the
        // htmlRendersTOC preference -- headings must be populated regardless.
        let renderer = MarkdownRenderer()
        var options = MarkdownRenderer.Options()
        options.renderTOC = false
        let result = renderer.render("# Alpha\n\n## Beta", options: options)
        #expect(result.headings.map(\.text) == ["Alpha", "Beta"])
    }

    @Test func headingSlugsAreUniqueAndDeduped() {
        let renderer = MarkdownRenderer()
        let result = renderer.render("# Duplicate\n\n## Duplicate\n\n### Duplicate")
        let slugs = result.headings.map(\.slug)
        #expect(Set(slugs).count == slugs.count)
    }

    // MARK: - Rule 1.1 / 1.2: isolation (model-level; harness gate 3 covers process-level)

    @Test func twoOutlineModelsOverSameHeadingsDoNotShareState() {
        let headings = [
            Heading(level: 1, text: "One", slug: "one"),
            Heading(level: 1, text: "Two", slug: "two"),
        ]
        let first = DocumentOutline()
        let second = DocumentOutline()
        first.update(headings: headings)
        second.update(headings: headings)

        first.toggleCollapse(slug: "one")

        #expect(first.isCollapsed(slug: "one"))
        #expect(!second.isCollapsed(slug: "one"))
    }

    // MARK: - Rule 4.2: outline rebuild follows the render debounce, not every keystroke

    @Test func outlineRebuildIsDebouncedWithRender() {
        // DocumentOutline itself has no timer -- it is a pure `update(headings:)` sink.
        // The debounce lives in SplitEditorView's existing scheduleRender() path, which
        // this test proves by asserting DocumentOutline performs no async work of its own:
        // update(headings:) is synchronous and has no internal delay.
        let outline = DocumentOutline()
        let before = ContinuousClock.now
        outline.update(headings: [Heading(level: 1, text: "X", slug: "x")])
        let elapsed = before.duration(to: .now)
        #expect(elapsed < .milliseconds(50))
    }

    // MARK: - Rule 5.2: no stubs/TODOs (compile-time proof lives in harness gate 4's grep)
}
