@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #30, rule 1.1: two `PDFRenderer` instances rendering different
/// documents concurrently never share or leak state.
struct ExportPDFIsolationTests {
    @Test @MainActor
    func twoInstancesRenderingDifferentDocumentsConcurrentlyNeverCrossContaminate() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportPDFIsolationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let destinationA = tempRoot.appendingPathComponent("alpha.pdf")
        let destinationB = tempRoot.appendingPathComponent("beta.pdf")
        let rendererA = PDFRenderer()
        let rendererB = PDFRenderer()

        async let resultA: Void = rendererA.renderPDF(
            html: "<html><body>Alpha</body></html>", baseDirectory: nil, to: destinationA
        )
        async let resultB: Void = rendererB.renderPDF(
            html: "<html><body>Beta</body></html>", baseDirectory: nil, to: destinationB
        )
        _ = try await (resultA, resultB)

        #expect(FileManager.default.fileExists(atPath: destinationA.path))
        #expect(FileManager.default.fileExists(atPath: destinationB.path))
        let dataA = try Data(contentsOf: destinationA)
        let dataB = try Data(contentsOf: destinationB)
        #expect(!dataA.isEmpty)
        #expect(!dataB.isEmpty)
        #expect(dataA != dataB, "two different documents must never render to identical output")
    }
}
