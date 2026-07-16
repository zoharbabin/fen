@testable import FenCore
import Foundation
import Testing
import WebKit

/// Reproduces the bug behind an actual user report: a broken Mermaid diagram (invalid
/// syntax in the user's Markdown, not a Fen defect) silently failed to render, leaving raw
/// fenced-code text on screen with no indication anything went wrong -- easy to mistake for
/// a Fen bug rather than a typo in the diagram. The root cause was worse than a missing
/// message: `mermaid.init.js`'s loop `await`ed `mermaid.render()` with no `try`/`catch`, so
/// one broken diagram threw out of the whole `init()` function and silently killed every
/// *other* Mermaid diagram later in the same document too. `renderErrorPanel` in
/// `mermaid.init.js` now catches per-diagram and shows a plain-English translation of the
/// failure (for the failure signatures we've verified by hand against Mermaid's real parser
/// -- see `friendlyMermaidError` in `mermaid.init.js`), with Mermaid's raw grammar-dump
/// message collapsed behind a "Show Mermaid's raw parser output" disclosure rather than
/// shown as the primary message: that raw message names internal Jison grammar terminals
/// (`BRKT`, `point_start`, `AXIS-TEXT-DELIMITER`) that mean nothing to a non-technical reader.
/// When no verified translation matches, the panel says so honestly and shows the raw
/// message expanded by default, rather than inventing a guess. A string-content check on the
/// composed HTML can't see any of this -- Mermaid's renderer and the try/catch only run once
/// real JS executes in a `WKWebView`, so this loads real composed HTML end-to-end per the
/// repo's e2e policy.
@Suite("Mermaid error panel")
struct MermaidErrorPanelVerifyTest {
    @Test("A broken diagram shows an in-preview error panel instead of silently failing")
    @MainActor
    func brokenDiagramShowsErrorPanel() async throws {
        let webView = try await renderQuadrantColonBugWebView()

        let panelAppeared = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-error').length === 1"
        )
        #expect(panelAppeared, "Expected exactly one error panel for the broken diagram")

        let headingText = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-heading').textContent"
        ) as? String ?? ""
        #expect(
            headingText.contains("syntax problem in the Markdown"),
            "Expected the panel to point at the Markdown, not at Fen, got: \(headingText)"
        )

        let messageText = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-message').textContent"
        ) as? String ?? ""
        #expect(
            messageText.contains("COLON") && messageText.contains("line"),
            "Expected Mermaid's own raw parse error still available, got: \(messageText)"
        )

        let helpLinkHref = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-help a') ? " +
                "document.querySelector('.fen-mermaid-error-help a').getAttribute('href') : null"
        ) as? String
        #expect(helpLinkHref == "https://mermaid.js.org/intro/syntax-reference.html")

        let sourceShown = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-source pre') ? " +
                "document.querySelector('.fen-mermaid-error-source pre').textContent : ''"
        ) as? String ?? ""
        #expect(
            sourceShown.contains("quadrant-2 Best value: cheap and solid"),
            "Expected the raw diagram source preserved for the reader to fix, got: \(sourceShown)"
        )
    }

    @Test("The colon-in-label failure gets a plain-English summary with the real document line")
    @MainActor
    func colonInLabelGetsFriendlySummaryWithDocumentLine() async throws {
        let webView = try await renderQuadrantColonBugWebView()

        let panelAppeared = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-error').length === 1"
        )
        #expect(panelAppeared)

        let summaryText = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-summary').textContent"
        ) as? String ?? ""
        #expect(
            summaryText.contains("colon") && summaryText.lowercased().contains("quadrantchart"),
            "Expected a plain-English explanation of the colon-in-label failure, got: \(summaryText)"
        )
        let lineFailureMessage = "Expected the document line (fence's sourcepos starts at document line 3; " +
            "the broken quadrant-2 line sits at document line 9 -- see documentLine's verified offset math " +
            "in mermaid.init.js), got: \(summaryText)"
        #expect(summaryText.contains("line 9 of your document"), Comment(rawValue: lineFailureMessage))
    }

    /// Shared repro for the colon-in-label failure: a broken `quadrantChart` diagram preceded
    /// by an intro paragraph, so the fence's `data-sourcepos` start line (3) isn't line 1 --
    /// this is what proves `documentLine()`'s offset math, not just that it returns *some* number.
    @MainActor
    private func renderQuadrantColonBugWebView() async throws -> WKWebView {
        let markdown = """
        Some intro text.

        ```mermaid
        quadrantChart
            title Bad label
            x-axis Low --> High
            y-axis Low --> High
            quadrant-1 A
            quadrant-2 Best value: cheap and solid
            quadrant-3 C
            quadrant-4 D
            Foo: [0.5, 0.5]
        ```
        """
        var options = MarkdownRenderer.Options()
        options.sourcePositions = true
        return try await renderPreviewWebView(markdown: markdown, options: options) { prefs in
            prefs.htmlMermaid = true
        }
    }

    @Test("A single-dash flowchart arrow gets a plain-English explanation")
    @MainActor
    func singleDashArrowGetsFriendlyMessage() async throws {
        let markdown = """
        ```mermaid
        flowchart TD
            A -> B
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlMermaid = true
        }

        let panelAppeared = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-error').length === 1"
        )
        #expect(panelAppeared)

        let summaryText = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-summary').textContent"
        ) as? String ?? ""
        #expect(
            summaryText.contains("single dash") && summaryText.contains("-->"),
            "Expected a plain-English explanation naming the two-dash fix, got: \(summaryText)"
        )
    }

    @Test("An unrecognized diagram type gets a plain-English explanation")
    @MainActor
    func unknownDiagramTypeGetsFriendlyMessage() async throws {
        let markdown = """
        ```mermaid
        notARealDiagramType
            foo bar
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlMermaid = true
        }

        let panelAppeared = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-error').length === 1"
        )
        #expect(panelAppeared)

        let summaryText = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-summary').textContent"
        ) as? String ?? ""
        #expect(
            summaryText.contains("doesn't recognize this as a Mermaid diagram type"),
            "Expected a plain-English explanation of the unknown diagram type, got: \(summaryText)"
        )
    }

    @Test("An unrecognized failure signature falls back honestly instead of guessing")
    @MainActor
    func unrecognizedFailureFallsBackHonestly() async throws {
        // erDiagram has a verified raw-error signature (see the mermaid.init.js comment and
        // the earlier hand investigation) but no plain-English pattern implemented for it --
        // deliberately chosen to exercise the fallback path rather than a translated one.
        let markdown = """
        ```mermaid
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            this is not valid at all !!
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlMermaid = true
        }

        let panelAppeared = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-error').length === 1"
        )
        #expect(panelAppeared)

        let summaryText = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-summary').textContent"
        ) as? String ?? ""
        #expect(
            summaryText.contains("doesn't have a plain-English translation"),
            "Expected an honest fallback rather than a guessed translation, got: \(summaryText)"
        )

        let detailsOpen = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-mermaid-error-technical').hasAttribute('open')"
        ) as? Bool ?? false
        #expect(detailsOpen, "Expected the raw technical output expanded by default when there's no translation")
    }

    @Test("A broken diagram doesn't take down other diagrams later in the same document")
    @MainActor
    func brokenDiagramDoesNotBlockLaterDiagrams() async throws {
        let markdown = """
        ```mermaid
        quadrantChart
            title Bad label
            quadrant-1 A
            quadrant-2 Bad: label
            quadrant-3 C
            quadrant-4 D
            Foo: [0.5, 0.5]
        ```

        ```mermaid
        graph TD
        A --> B
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlMermaid = true
        }

        let bothResolved = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-mermaid-error').length === 1 && " +
                "document.querySelectorAll('.fen-mermaid-container svg').length === 1"
        )
        #expect(
            bothResolved,
            "Expected the first diagram to show an error panel and the second to still render normally"
        )
    }
}
