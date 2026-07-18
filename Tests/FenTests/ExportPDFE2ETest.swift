import CoreGraphics
@testable import FenCore
import Foundation
import Testing

/// End-to-end test for issue #30: drives the real export flow -- `DocumentPDFExporter` render
/// through `PDFRenderer` -- against a fixture document with a real sidecar image, then asserts a
/// real paginated PDF landed on disk (macOS) or was produced as `Data` (iOS). Mirrors
/// `ExportHTMLE2ETest`'s shape: the modal picker (`NSSavePanel`/`.fileExporter`) itself can't be
/// driven headlessly, so this exercises every step around it with real production types.
@Suite("Exporting a document to PDF produces a real paginated PDF file")
struct ExportPDFE2ETest {
    private func makeFixture() throws -> (documentURL: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportPDFE2ETest-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(
            to: documentDirectory.appendingPathComponent("photo.png")
        )
        return (documentDirectory.appendingPathComponent("notes.md"), tempRoot)
    }

    #if os(macOS)
        @Test @MainActor
        func exportWritesARealPaginatedPDFFile() async throws {
            let (documentURL, tempRoot) = try makeFixture()
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let preferences =
                try Preferences(defaults: #require(UserDefaults(suiteName: "export.pdf.e2e.\(UUID().uuidString)")))

            let html = DocumentPDFExporter().export(
                markdown: "---\ntitle: Notes\n---\n\n# Notes\n\n![photo](photo.png)",
                documentURL: documentURL,
                preferences: preferences
            )
            #expect(html.contains("data:image/png;base64,"))
            #expect(!html.contains("title: Notes"), "front matter must never render as visible body text")

            let destination = tempRoot.appendingPathComponent("export.pdf")
            try await PDFRenderer().renderPDF(
                html: html, baseDirectory: documentURL.deletingLastPathComponent(), to: destination
            )

            #expect(FileManager.default.fileExists(atPath: destination.path))
            let data = try Data(contentsOf: destination)
            #expect(data.starts(with: Data("%PDF".utf8)), "output must be a real PDF file")
            let provider = CGDataProvider(data: data as CFData)
            let pdfDocument = provider.flatMap { CGPDFDocument($0) }
            #expect((pdfDocument?.numberOfPages ?? 0) >= 1)
        }
    #else
        @Test @MainActor
        func exportProducesRealPDFData() async throws {
            let (documentURL, tempRoot) = try makeFixture()
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let preferences =
                try Preferences(defaults: #require(UserDefaults(suiteName: "export.pdf.e2e.\(UUID().uuidString)")))

            let html = DocumentPDFExporter().export(
                markdown: "---\ntitle: Notes\n---\n\n# Notes\n\n![photo](photo.png)",
                documentURL: documentURL,
                preferences: preferences
            )
            #expect(html.contains("data:image/png;base64,"))
            #expect(!html.contains("title: Notes"), "front matter must never render as visible body text")

            let data = try await PDFRenderer().renderPDFData(
                html: html, baseDirectory: documentURL.deletingLastPathComponent()
            )
            #expect(data.starts(with: Data("%PDF".utf8)), "output must be a real PDF file")
        }
    #endif
}
