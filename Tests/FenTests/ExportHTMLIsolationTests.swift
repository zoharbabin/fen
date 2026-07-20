@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #31, rule 1.1: two `ExportAssetResolver` instances used
/// concurrently against two different documents never share or leak state -- `resolve` is a
/// pure function of its arguments, so this proves there's no static/shared mutable state
/// backing it.
struct ExportHTMLIsolationTests {
    private func makeFixture(name: String) throws -> (documentDirectory: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportHTMLIsolationTests-\(name)-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: documentDirectory.appendingPathComponent("\(name).png"))
        return (documentDirectory, tempRoot)
    }

    @Test @MainActor
    func twoInstancesExportingDifferentDocumentsConcurrentlyNeverCrossContaminate() async throws {
        let fixtureA = try makeFixture(name: "alpha")
        let fixtureB = try makeFixture(name: "beta")
        defer {
            try? FileManager.default.removeItem(at: fixtureA.tempRoot)
            try? FileManager.default.removeItem(at: fixtureB.tempRoot)
        }

        let resolverA = ExportAssetResolver()
        let resolverB = ExportAssetResolver()

        async let resultA = Task { @MainActor in
            resolverA.resolve(
                html: #"<img src="alpha.png">"#,
                documentDirectory: fixtureA.documentDirectory,
                mode: .linkedAssets(exportBaseName: "alpha-export")
            )
        }.value
        async let resultB = Task { @MainActor in
            resolverB.resolve(
                html: #"<img src="beta.png">"#,
                documentDirectory: fixtureB.documentDirectory,
                mode: .linkedAssets(exportBaseName: "beta-export")
            )
        }.value

        let (outputA, outputB) = await (resultA, resultB)

        #expect(outputA.assets.map(\.relativePath) == ["alpha-export.assets/alpha.png"])
        #expect(outputB.assets.map(\.relativePath) == ["beta-export.assets/beta.png"])
        #expect(outputA.assets.first?.sourceFileURL == fixtureA.documentDirectory.appendingPathComponent("alpha.png"))
        #expect(outputB.assets.first?.sourceFileURL == fixtureB.documentDirectory.appendingPathComponent("beta.png"))
        #expect(outputA.html.contains("alpha-export.assets/alpha.png"))
        #expect(outputB.html.contains("beta-export.assets/beta.png"))
        #expect(!outputA.html.contains("beta"), "resolver A's output must never reference document B's assets")
        #expect(!outputB.html.contains("alpha"), "resolver B's output must never reference document A's assets")
    }
}
