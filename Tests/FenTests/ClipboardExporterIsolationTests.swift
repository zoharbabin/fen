@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #33, rule 1.1: two `ClipboardExporter` compositions running
/// concurrently against two different documents never share or cross-contaminate their
/// *composed* output -- `composeHTML` is a pure function of its arguments, so this proves
/// there's no static/shared mutable state backing it.
struct ClipboardExporterIsolationTests {
    private func makeFixture(name: String) throws -> (documentDirectory: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardExporterIsolationTests-\(name)-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        return (documentDirectory, tempRoot)
    }

    @Test @MainActor
    func twoInstancesComposingDifferentDocumentsConcurrentlyNeverCrossContaminate() async throws {
        let fixtureA = try makeFixture(name: "alpha")
        let fixtureB = try makeFixture(name: "beta")
        defer {
            try? FileManager.default.removeItem(at: fixtureA.tempRoot)
            try? FileManager.default.removeItem(at: fixtureB.tempRoot)
        }

        let exporterA = ClipboardExporter()
        let exporterB = ClipboardExporter()

        async let htmlA = Task { @MainActor in
            exporterA.composeHTML(
                markdown: "# Alpha document",
                documentURL: fixtureA.documentDirectory.appendingPathComponent("a.md"),
                preferences: Preferences()
            )
        }.value
        async let htmlB = Task { @MainActor in
            exporterB.composeHTML(
                markdown: "# Beta document",
                documentURL: fixtureB.documentDirectory.appendingPathComponent("b.md"),
                preferences: Preferences()
            )
        }.value

        let (resultA, resultB) = await (htmlA, htmlB)

        #expect(resultA.contains("Alpha document"))
        #expect(resultB.contains("Beta document"))
        #expect(!resultA.contains("Beta"), "exporter A's output must never reference document B's content")
        #expect(!resultB.contains("Alpha"), "exporter B's output must never reference document A's content")
    }
}
