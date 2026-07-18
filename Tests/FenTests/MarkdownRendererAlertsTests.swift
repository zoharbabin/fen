@testable import FenCore
import Testing

/// Alerts extension (issue #29) coverage, split from `MarkdownRendererTests` to keep that
/// suite under swiftlint's file/type length limits -- mirrors the `CodeBlockCoverageTests`
/// split in `GFMFeatureCoverageTests.swift`.
@Suite("MarkdownRenderer Alerts Tests")
struct MarkdownRendererAlertsTests {
    let renderer = MarkdownRenderer()

    @Test(
        "Each of the 5 alert types renders with its own class and title when enabled",
        arguments: [
            ("NOTE", "note", "Note"),
            ("TIP", "tip", "Tip"),
            ("IMPORTANT", "important", "Important"),
            ("WARNING", "warning", "Warning"),
            ("CAUTION", "caution", "Caution"),
        ]
    )
    func alertsRenderEachType(marker: String, className: String, title: String) {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let result = renderer.render("> [!\(marker)]\n> Body text.", options: opts)
        #expect(result.html.contains("markdown-alert markdown-alert-\(className)"))
        #expect(result.html.contains("markdown-alert-title\">\(title)</p>"))
        #expect(result.html.contains("<p>Body text.</p>"))
    }

    @Test("Alert marker matching is case-insensitive")
    func alertsCaseInsensitive() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let result = renderer.render("> [!note]\n> lowercase marker.", options: opts)
        #expect(result.html.contains("markdown-alert-note"))
    }

    @Test("A marker alone with no body still renders as an alert")
    func alertsMarkerAlone() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let result = renderer.render("> [!TIP]", options: opts)
        #expect(result.html.contains("markdown-alert markdown-alert-tip"))
    }

    @Test("An unrecognized bracket marker is left as a literal blockquote")
    func alertsUnrecognizedMarker() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let result = renderer.render("> [!BOGUS]\n> body", options: opts)
        #expect(!result.html.contains("markdown-alert"))
        #expect(result.html.contains("[!BOGUS]"))
    }

    @Test("Trailing text on the marker line disqualifies the transform")
    func alertsRejectsTrailingTextOnMarkerLine() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let result = renderer.render("> [!NOTE] trailing text\n> body", options: opts)
        #expect(!result.html.contains("markdown-alert"))
        #expect(result.html.contains("[!NOTE] trailing text"))
    }

    @Test("A blockquote nested inside another blockquote never qualifies")
    func alertsRejectsNestedBlockquote() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let result = renderer.render("> > [!NOTE]\n> > nested", options: opts)
        #expect(!result.html.contains("markdown-alert"))
    }

    @Test("A blockquote nested inside a list item never qualifies")
    func alertsRejectsBlockquoteInsideListItem() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let result = renderer.render("- item\n  > [!NOTE]\n  > in list", options: opts)
        #expect(!result.html.contains("markdown-alert"))
    }

    @Test("A literal marker inside a fenced code block is never touched")
    func alertsSkipsCodeBlock() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let md = """
        ```
        > [!NOTE]
        > in code
        ```
        """
        let result = renderer.render(md, options: opts)
        #expect(!result.html.contains("markdown-alert"))
        #expect(result.html.contains("[!NOTE]"))
    }

    @Test("Two separate alerts in one document both render independently")
    func alertsMultipleInOneDocument() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = true
        let md = """
        > [!NOTE]
        > First.

        > [!CAUTION]
        > Second.
        """
        let result = renderer.render(md, options: opts)
        #expect(result.html.contains("markdown-alert-note"))
        #expect(result.html.contains("markdown-alert-caution"))
    }

    @Test("Alerts render as literal blockquotes when the extension is disabled")
    func alertsDisabled() {
        var opts = MarkdownRenderer.Options()
        opts.alerts = false
        let result = renderer.render("> [!NOTE]\n> Text here.", options: opts)
        #expect(!result.html.contains("markdown-alert"))
        #expect(result.html.contains("[!NOTE]"))
    }
}
