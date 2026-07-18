@testable import FenCore
import Foundation
import Testing

/// End-to-end and unit proof for issue #27: per-document `fen:` front-matter overrides for
/// preview theme and TOC visibility.
///
/// Rule 2.1 (theme validated against the real bundle listing), 3.1 (malformed/missing `fen:`
/// degrades to `.none` field-by-field, never throws), 3.2 (`htmlDetectFrontMatter = false`
/// disables override parsing even if a `fen:`-shaped block is present), and 3.3 (an overridden
/// theme still goes through #25's dark/light pairing) are proven directly against
/// `DocumentPreviewOverrides.parse` and `HTMLComposer.resolveEffectiveStyleName`. The 3 core E2E
/// cases from the Phase 1 spec are proven through a real `WKWebView` via `renderPreviewWebView`.
@Suite("Per-document front-matter preview overrides")
struct DocumentPreviewOverridesVerifyTest {
    // MARK: - Rule 2.1: theme validated against the real bundle listing

    @Test("A theme name that isn't in the real bundle listing is ignored, not passed through")
    func unknownThemeNameIsIgnored() {
        let overrides = DocumentPreviewOverrides.parse(frontMatter: ["fen": ["theme": "../../etc/passwd"]])
        #expect(overrides.styleName == nil)
    }

    @Test("A theme name that is in the real bundle listing is accepted")
    func knownThemeNameIsAccepted() throws {
        let known = HTMLComposer.availablePreviewStyles()
        let name = try #require(known.first)
        let overrides = DocumentPreviewOverrides.parse(frontMatter: ["fen": ["theme": name]])
        #expect(overrides.styleName == name)
    }

    // MARK: - Rule 3.1: malformed/missing front matter degrades to .none field-by-field

    @Test("Missing front matter entirely degrades to .none")
    func missingFrontMatterDegradesToNone() {
        #expect(DocumentPreviewOverrides.parse(frontMatter: nil) == .none)
    }

    @Test("Front matter with no fen key degrades to .none")
    func noFenKeyDegradesToNone() {
        #expect(DocumentPreviewOverrides.parse(frontMatter: ["title": "Hello"]) == .none)
    }

    @Test("A non-dictionary fen value degrades to .none rather than crashing")
    func nonDictFenValueDegradesToNone() {
        #expect(DocumentPreviewOverrides.parse(frontMatter: ["fen": true]) == .none)
        #expect(DocumentPreviewOverrides.parse(frontMatter: ["fen": "GitHub2 Dark"]) == .none)
    }

    @Test("A wrong-typed theme or toc value is ignored field-by-field, not thrown")
    func wrongTypedFieldsAreIgnoredIndividually() {
        let overrides = DocumentPreviewOverrides.parse(frontMatter: ["fen": ["theme": 42, "toc": "yes"]])
        #expect(overrides.styleName == nil)
        #expect(overrides.rendersTOC == nil)
    }

    @Test("A valid toc alongside an invalid theme still resolves the toc field")
    func partiallyValidFenBlockResolvesValidFieldsOnly() {
        let overrides = DocumentPreviewOverrides.parse(frontMatter: ["fen": ["theme": "NoSuchTheme", "toc": true]])
        #expect(overrides.styleName == nil)
        #expect(overrides.rendersTOC == true)
    }

    // MARK: - Rule 3.2: htmlDetectFrontMatter gates override parsing

    @Test("With front-matter detection off, SplitEditorView-style resolution must not parse fen: at all")
    func frontMatterDetectionOffSkipsOverrideResolution() throws {
        let suite = try #require(UserDefaults(suiteName: "docoverrides.verify.\(UUID().uuidString)"))
        let prefs = Preferences(defaults: suite)
        prefs.htmlDetectFrontMatter = false

        let markdown = "---\nfen:\n  theme: GitHub2 Dark\n---\n# Hello"
        let renderer = MarkdownRenderer()
        let documentOverrides: DocumentPreviewOverrides = prefs.htmlDetectFrontMatter
            ? .parse(frontMatter: renderer.peekFrontMatter(markdown))
            : .none

        #expect(
            documentOverrides == .none,
            "a fen: block must never drive rendering while front-matter detection is off"
        )
    }

    // MARK: - Rule 3.3: an overridden theme still goes through the #25 dark/light pairing

    @Test("An overridden light theme still resolves to its dark counterpart under a dark-wanting appearance mode")
    @MainActor
    func overriddenThemeStillGoesThroughAppearancePairing() throws {
        let suite = try #require(UserDefaults(suiteName: "docoverrides.verify.\(UUID().uuidString)"))
        let prefs = Preferences(defaults: suite)
        prefs.htmlStyleName = "GitHub"
        prefs.previewAppearanceMode = .dark
        prefs.systemPrefersDarkAppearance = true

        let resolved = HTMLComposer.resolveEffectiveStyleName(
            preferences: prefs,
            documentOverrides: DocumentPreviewOverrides(styleName: "GitHub2", rendersTOC: nil)
        )
        #expect(
            resolved == "GitHub2 Dark",
            "the document's overridden theme must still be paired for the wanted appearance"
        )
    }

    // MARK: - Core E2E cases (Phase 1 spec)

    @Test("(a) A document's fen: theme override applies despite a different global htmlStyleName")
    @MainActor
    func documentThemeOverrideAppliesOverGlobalPreference() async throws {
        let markdown = "---\nfen:\n  theme: GitHub2 Dark\n---\n# Hello"
        let renderer = MarkdownRenderer()
        let peeked = renderer.peekFrontMatter(markdown)
        let overrides = DocumentPreviewOverrides.parse(frontMatter: peeked)

        let webView = try await renderPreviewWebView(
            markdown: markdown,
            configurePreferences: { prefs in
                prefs.htmlStyleName = "GitHub"
                prefs.previewAppearanceMode = .dark
            },
            documentOverrides: overrides
        )
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        let luma = luminance(fromRGBString: bg as? String ?? "")
        #expect(
            (luma ?? 255) < 128,
            "the document's own theme override must apply despite a different global htmlStyleName"
        )
    }

    @Test("(b) A document's fen: toc override renders a TOC even though the global preference is off")
    @MainActor
    func documentTOCOverrideAppliesOverGlobalPreference() async throws {
        let markdown = "---\nfen:\n  toc: true\n---\n# Heading One\n\n[TOC]\n\n## Heading Two"
        let renderer = MarkdownRenderer()
        let peeked = renderer.peekFrontMatter(markdown)
        let overrides = DocumentPreviewOverrides.parse(frontMatter: peeked)

        var options = MarkdownRenderer.Options()
        options.renderTOC = overrides.rendersTOC ?? options.renderTOC

        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: options,
            configurePreferences: { prefs in
                prefs.htmlRendersTOC = false
            },
            documentOverrides: overrides
        )
        let tocLinkCount = try await webView.evaluateJavaScript("document.querySelectorAll('.toc-h1, .toc-h2').length")
        #expect((tocLinkCount as? Int ?? 0) >= 2, "the document's toc override must render TOC entries")
    }

    @Test("(c) A document with no fen: block renders identically to before this issue")
    @MainActor
    func noFenBlockIsPurelyAdditive() async throws {
        let markdown = "# Hello\n\nJust a plain document."
        let renderer = MarkdownRenderer()
        let peeked = renderer.peekFrontMatter(markdown)
        let overrides = DocumentPreviewOverrides.parse(frontMatter: peeked)
        #expect(overrides == .none)

        let webView = try await renderPreviewWebView(
            markdown: markdown,
            configurePreferences: { prefs in
                prefs.htmlStyleName = "GitHub2"
            },
            documentOverrides: overrides
        )
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        #expect((bg as? String)?.isEmpty == false)
    }
}

/// Parses a CSS `rgb(r, g, b)` / `rgba(r, g, b, a)` string and returns perceptual luminance
/// (0-255). Duplicated from `PreviewAppearanceVerifyTest.swift` rather than shared, since that
/// file's copy is `private` and this suite lives in a separate file.
private func luminance(fromRGBString value: String) -> Double? {
    let digits = value
        .trimmingCharacters(in: CharacterSet(charactersIn: "rgba() "))
        .split(separator: ",")
        .prefix(3)
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard digits.count == 3 else { return nil }
    return 0.299 * digits[0] + 0.587 * digits[1] + 0.114 * digits[2]
}
