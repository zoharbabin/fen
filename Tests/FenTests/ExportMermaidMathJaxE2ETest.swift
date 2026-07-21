import CoreGraphics
@testable import FenCore
import Foundation
import Testing
import WebKit

/// End-to-end proof for issue #84: `HTMLComposer.composeForExport`/`composeForPrint` used to
/// skip Mermaid/MathJax entirely, so a diagram or math expression that rendered fine in the
/// live preview showed up as raw ` ```mermaid `/`$...$` text in exported HTML, printouts, and
/// PDFs. Loads the real composed HTML through a real `WKWebView` (per this repo's
/// verify-end-to-end policy) rather than asserting on the HTML string, since Mermaid/MathJax
/// only run once real JS executes.
@Suite("Mermaid and MathJax render in export/print output")
struct ExportMermaidMathJaxE2ETest {
    private func preferences(mermaid: Bool, mathJax: Bool) throws -> Preferences {
        let prefs = try Preferences(
            defaults: #require(UserDefaults(suiteName: "export.mermaid-mathjax.e2e.\(UUID().uuidString)"))
        )
        prefs.htmlMermaid = mermaid
        prefs.htmlMathJax = mathJax
        prefs.htmlMathJaxInlineDollar = mathJax
        return prefs
    }

    @MainActor
    private func loadComposedExportHTML(_ html: String) async throws -> WKWebView {
        let handler = PreviewSchemeHandler()
        handler.html = html

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)

        let delegate = NavDelegate()
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: PreviewSchemeHandler.previewURL))
        try await delegate.waitForFinish()
        return webView
    }

    @Test("Mermaid diagram renders as SVG in exported HTML, not raw fenced code")
    @MainActor
    func mermaidRendersInExportedHTML() async throws {
        let prefs = try preferences(mermaid: true, mathJax: false)
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("```mermaid\ngraph TD; A-->B;\n```", options: .from(preferences: prefs))

        let html = HTMLComposer().composeForExport(
            title: rendered.title,
            body: rendered.html,
            preferences: prefs,
            includeStyles: true,
            includeHighlighting: true
        )
        let webView = try await loadComposedExportHTML(html)

        let rendered2 = try await pollUntilTrue(webView, js: "!!document.querySelector('svg')", timeout: .seconds(10))
        #expect(rendered2, "Expected Mermaid to replace the fenced code block with an inline <svg> in exported HTML")

        let stillRaw = try await webView.evaluateJavaScript("!!document.querySelector('code.language-mermaid')")
        #expect((stillRaw as? Bool) == false, "The raw mermaid fenced code block must not remain in exported HTML")
    }

    @Test("MathJax math renders as SVG in exported HTML, not raw dollar-delimited text")
    @MainActor
    func mathJaxRendersInExportedHTML() async throws {
        let prefs = try preferences(mermaid: false, mathJax: true)
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("Inline math: $x+y$", options: .from(preferences: prefs))

        let html = HTMLComposer().composeForExport(
            title: rendered.title,
            body: rendered.html,
            preferences: prefs,
            includeStyles: true,
            includeHighlighting: true
        )
        let webView = try await loadComposedExportHTML(html)

        let mathRendered = try await pollUntilTrue(
            webView, js: "!!document.querySelector('mjx-container svg')", timeout: .seconds(10)
        )
        #expect(mathRendered, "Expected MathJax to render $x+y$ as an SVG inside an mjx-container in exported HTML")
    }

    @Test("Mermaid diagram renders as SVG in print/PDF-composed HTML")
    @MainActor
    func mermaidRendersInPrintComposedHTML() async throws {
        let prefs = try preferences(mermaid: true, mathJax: false)
        let renderer = MarkdownRenderer()
        let rendered = renderer.render("```mermaid\ngraph TD; A-->B;\n```", options: .from(preferences: prefs))

        let html = HTMLComposer().composeForPrint(title: rendered.title, body: rendered.html, preferences: prefs)
        let webView = try await loadComposedExportHTML(html)

        let rendered2 = try await pollUntilTrue(webView, js: "!!document.querySelector('svg')", timeout: .seconds(10))
        #expect(rendered2, "Expected Mermaid to replace the fenced code block with an inline <svg> in print HTML")
    }

    @Test("PDFRenderer waits for Mermaid to finish before capturing, producing a non-trivial PDF")
    @MainActor
    func pdfRendererWaitsForMermaidCompletion() async throws {
        #if os(macOS)
            let prefs = try preferences(mermaid: true, mathJax: false)
            let renderer = MarkdownRenderer()
            let rendered = renderer.render(
                "```mermaid\ngraph TD; A-->B; B-->C; C-->D;\n```", options: .from(preferences: prefs)
            )
            let html = HTMLComposer().composeForPrint(title: rendered.title, body: rendered.html, preferences: prefs)

            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ExportMermaidMathJaxE2ETest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let destination = tempRoot.appendingPathComponent("export.pdf")

            try await PDFRenderer().renderPDF(html: html, baseDirectory: nil, to: destination)

            let data = try Data(contentsOf: destination)
            #expect(data.starts(with: Data("%PDF".utf8)), "output must be a real PDF file")
            #expect(data.count > 2000, "a PDF capturing a rendered diagram should be larger than a near-blank page")
        #endif
    }
}
