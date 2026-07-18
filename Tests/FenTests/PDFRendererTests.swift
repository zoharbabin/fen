@testable import FenCore
import Foundation
import Testing

/// Proves issue #30 rules 3.1 (unwritable destination surfaces an error, not a crash) and 3.2
/// (bounded load timeout, not an unbounded hang).
struct PDFRendererTests {
    #if os(macOS)
        @Test @MainActor
        func writingToAnUnwritableDestinationThrowsRatherThanCrashes() async throws {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PDFRendererTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempRoot.path)
                try? FileManager.default.removeItem(at: tempRoot)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempRoot.path)

            let destination = tempRoot.appendingPathComponent("export.pdf")

            await #expect(throws: PDFRenderer.PDFRenderError.self) {
                try await PDFRenderer().renderPDF(
                    html: "<html><body>Hi</body></html>",
                    baseDirectory: nil,
                    to: destination
                )
            }
        }
    #endif

    @Test @MainActor
    func aLoadThatNeverFinishesFailsWithinTheBoundedTimeoutRatherThanHanging() async throws {
        #if os(macOS)
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PDFRendererTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let destination = tempRoot.appendingPathComponent("export.pdf")

            // A src referencing a scheme with no registered handler never fires didFinish on its
            // own within a reasonable window for the *main* frame -- but since the top-level
            // document itself always loads via fen-preview://, force the timeout path directly
            // by using an unreasonably short timeout instead of relying on load semantics.
            await #expect(throws: PDFRenderer.PDFRenderError.self) {
                try await PDFRenderer().renderPDF(
                    html: "<html><body>Hi</body></html>",
                    baseDirectory: nil,
                    to: destination,
                    loadTimeout: .zero
                )
            }
        #else
            await #expect(throws: PDFRenderer.PDFRenderError.self) {
                _ = try await PDFRenderer().renderPDFData(
                    html: "<html><body>Hi</body></html>",
                    baseDirectory: nil,
                    loadTimeout: .zero
                )
            }
        #endif
    }
}
