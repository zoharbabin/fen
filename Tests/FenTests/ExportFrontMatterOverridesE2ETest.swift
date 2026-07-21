@testable import FenCore
import Foundation
import Testing

// End-to-end proof for issue #85: a document's own `fen:` front-matter theme/TOC overrides,
// already respected by the live preview (issue #27), used to be silently ignored by
// export/print/CLI/clipboard output. Drives the real `fen-export` batch flow --
// `CLIExportArguments.parse` + `ExportCLIRunner.run` -- against a fixture document with a
// `fen:` block, per the issue's own repro, plus `DocumentPDFExporter` directly for the PDF path.
// Mirrors `CLIRunnerE2ETest`'s shape of exercising every step with real production types.
#if os(macOS)
    @Suite("Per-document fen: front-matter overrides reach export/CLI output")
    struct ExportFrontMatterOverridesE2ETest {
        private func makeFixture(frontMatter: String) throws -> (documentURL: URL, tempRoot: URL) {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ExportFrontMatterOverridesE2ETest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let documentURL = tempRoot.appendingPathComponent("notes.md")
            try "\(frontMatter)\n[TOC]\n\n# Notes\n\n## Section\n\nSome **bold** text.".write(
                to: documentURL, atomically: true, encoding: .utf8
            )
            return (documentURL, tempRoot)
        }

        @Test @MainActor
        func fenExportCLIUsesTheDocumentsFrontMatterThemeAndTOC() async throws {
            let (documentURL, tempRoot) = try makeFixture(
                frontMatter: "---\nfen:\n  theme: Clearness\n  toc: true\n---"
            )
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let preferences = try Preferences(
                defaults: #require(UserDefaults(suiteName: "cli.frontmatter.e2e.\(UUID().uuidString)"))
            )
            preferences.htmlStyleName = "GitHub"
            preferences.htmlRendersTOC = false

            let arguments = try CLIExportArguments.parse([documentURL.path])
            let results = await ExportCLIRunner().run(arguments, preferences: preferences)

            #expect(results.count == 1)
            #expect(results[0].succeeded)
            let outputURL = try #require(results[0].outputURL)
            let html = try String(contentsOf: outputURL, encoding: .utf8)

            #expect(
                html.contains("Hiragino Sans GB"),
                "fen-export must use the document's fen: theme (Clearness), not the global htmlStyleName (GitHub)"
            )
            #expect(
                html.contains("class=\"toc-h1\""),
                "fen-export must render a real TOC from fen: toc: true even though the global preference is off"
            )
            #expect(html.contains("<strong>bold</strong>"), "the rest of the document must still render normally")
        }

        @Test @MainActor
        func fenExportCLIWithoutFrontMatterIsUnaffected() async throws {
            let (documentURL, tempRoot) = try makeFixture(frontMatter: "")
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let preferences = try Preferences(
                defaults: #require(UserDefaults(suiteName: "cli.frontmatter.e2e.\(UUID().uuidString)"))
            )
            preferences.htmlStyleName = "GitHub"

            let arguments = try CLIExportArguments.parse([documentURL.path])
            let results = await ExportCLIRunner().run(arguments, preferences: preferences)

            #expect(results[0].succeeded)
            let html = try String(contentsOf: #require(results[0].outputURL), encoding: .utf8)
            #expect(
                !html.contains("Hiragino Sans GB"),
                "a document with no fen: block must export using global preferences"
            )
        }

        @Test @MainActor
        func pdfExportUsesTheDocumentsFrontMatterTheme() async throws {
            let (documentURL, tempRoot) = try makeFixture(frontMatter: "---\nfen:\n  theme: Clearness\n---")
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let markdown = try String(contentsOf: documentURL, encoding: .utf8)
            let preferences = try Preferences(
                defaults: #require(UserDefaults(suiteName: "pdf.frontmatter.e2e.\(UUID().uuidString)"))
            )
            preferences.htmlStyleName = "GitHub"

            let html = DocumentPDFExporter().export(
                markdown: markdown,
                documentURL: documentURL,
                preferences: preferences
            )

            #expect(
                html.contains("Hiragino Sans GB"),
                "Export to PDF's print-composed HTML must use the document's fen: theme override"
            )

            let destination = tempRoot.appendingPathComponent("notes.pdf")
            try await PDFRenderer().renderPDF(
                html: html,
                baseDirectory: documentURL.deletingLastPathComponent(),
                to: destination
            )
            let data = try Data(contentsOf: destination)
            #expect(data.starts(with: Data("%PDF".utf8)), "output must be a real PDF file")
        }
    }
#endif
