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
        // Checks for the specific heading text, not a bare "Beta"/"Alpha" substring -- the
        // vendored highlight.min.js this composes in by default (rule 5.1, issue #31) contains
        // "Beta" as a language keyword, unrelated to any cross-document leak, and would otherwise
        // false-fail this assertion regardless of isolation.
        #expect(
            !resultA.contains("Beta document"), "exporter A's output must never reference document B's content"
        )
        #expect(
            !resultB.contains("Alpha document"), "exporter B's output must never reference document A's content"
        )
    }
}
