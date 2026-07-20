@testable import FenCore
import Foundation
import Testing
#if os(macOS)
    import AppKit
#endif

/// Harness gate 3 for issue #32, rule 1.1: a print-panel flow and a PDF-export flow running
/// concurrently on two separate `PDFRenderer` instances never share or corrupt state --
/// particularly the process-wide `PrintOperationGate` both `printDocument` and `renderPDF`
/// route through via `runModalPrintOperation`.
struct PrintIsolationTests {
    #if os(macOS)
        /// Drives the same offscreen-load + `runModalPrintOperation` machinery `printDocument`
        /// uses, but with the panel hidden and the job discarded -- so this test never pops a
        /// real, unattended system dialog.
        @MainActor
        private func runSilentPrint(_ renderer: PDFRenderer, html: String) async throws -> Bool {
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
        func aPrintRequestAndAnExportRequestRunningConcurrentlyNeverCorruptEachOther() async throws {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrintIsolationTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let destination = tempRoot.appendingPathComponent("export.pdf")

            let printRenderer = PDFRenderer()
            let exportRenderer = PDFRenderer()

            async let printRan = runSilentPrint(printRenderer, html: "<html><body>Printed</body></html>")
            async let exportResult: Void = exportRenderer.renderPDF(
                html: "<html><body>Exported</body></html>", baseDirectory: nil, to: destination
            )

            _ = try await printRan
            _ = try await exportResult

            #expect(FileManager.default.fileExists(atPath: destination.path))
            let data = try Data(contentsOf: destination)
            #expect(!data.isEmpty)
        }
    #endif
}
