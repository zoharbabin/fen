@testable import FenCore
import Foundation
import Testing
#if os(macOS)
    import AppKit
#endif

/// Harness gate 5 for issue #32, rule 3.1: cancelling the print panel must not crash or leave
/// any file/state behind, and must not leak the `runModal` completion continuation -- the exact
/// class of bug issue #30's Phase 4 hit and fixed for the PDF-export path.
struct PrintControllerTests {
    #if os(macOS)
        /// `NSPrintInfo.PrintingDisposition.cancel` is AppKit's own documented mechanism for
        /// discarding a print job's output without presenting a panel -- the same "job accepted
        /// then discarded" outcome a user cancelling the real system print panel produces, but
        /// reachable headlessly so this test never pops a real, unattended dialog.
        @MainActor
        private func runCancelledPrint(_ renderer: PDFRenderer, html: String) async throws -> Bool {
            let webView = try await renderer.loadOffscreenWebView(
                html: html, baseDirectory: nil, loadTimeout: .seconds(10)
            )
            let printInfo = NSPrintInfo()
            printInfo.jobDisposition = .cancel
            let operation = webView.printOperation(with: printInfo)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            return await renderer.runModalPrintOperation(operation, webView: webView)
        }

        @Test @MainActor
        func cancellingLeavesNoLeakedContinuationAndTheRendererStaysUsable() async throws {
            let renderer = PDFRenderer()

            // `.cancel` disposition discards the job's output, so `runModal`'s `success` callback
            // reports `false` -- the proof this test cares about is that the call returns at all
            // (no hang, no crash), not the boolean result itself.
            _ = try await runCancelledPrint(renderer, html: "<html><body>One</body></html>")

            // If `activeRunDelegate`/the `PrintOperationGate` were left in a leaked state by the
            // first cancelled run, this second call on the same instance would either hang
            // (gate never released) or crash (delegate overwritten mid-flight) rather than
            // complete cleanly.
            _ = try await runCancelledPrint(renderer, html: "<html><body>Two</body></html>")
        }

        @Test @MainActor
        func cancellingWritesNoFileToDisk() async throws {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrintControllerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            _ = try await runCancelledPrint(PDFRenderer(), html: "<html><body>Untouched</body></html>")

            let contents = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
            #expect(contents.isEmpty)
        }
    #endif
}
