@testable import FenCore
import Foundation
import Testing

// End-to-end test for issue #34: drives the real `fen-export` batch flow --
// `CLIExportArguments.parse` + `ExportCLIRunner.run` -- against fixture documents, then asserts
// real files landed on disk with real rendered content. Mirrors `ExportHTMLE2ETest`'s shape of
// exercising every step with real production types (unit-level argument/error-path coverage
// already lives in `CLIRunnerTests`).
#if os(macOS)
    @Suite("Running fen-export against real files produces real HTML/PDF output")
    struct CLIRunnerE2ETest {
        private func makeFixture() throws -> (documentURL: URL, tempRoot: URL) {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CLIRunnerE2ETest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let documentURL = tempRoot.appendingPathComponent("notes.md")
            try "---\ntitle: Notes\n---\n\n# Notes\n\nSome **bold** text.".write(
                to: documentURL, atomically: true, encoding: .utf8
            )
            return (documentURL, tempRoot)
        }

        @Test @MainActor
        func exportingToHTMLWritesARealFileWithRenderedContent() async throws {
            let (documentURL, tempRoot) = try makeFixture()
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let preferences =
                try Preferences(defaults: #require(UserDefaults(suiteName: "cli.e2e.\(UUID().uuidString)")))
            let arguments = try CLIExportArguments.parse([documentURL.path])
            let results = await ExportCLIRunner().run(arguments, preferences: preferences)

            #expect(results.count == 1)
            #expect(results[0].succeeded)
            let outputURL = try #require(results[0].outputURL)
            #expect(outputURL.lastPathComponent == "notes.html")
            let html = try String(contentsOf: outputURL, encoding: .utf8)
            #expect(html.contains("<title>Notes</title>"))
            #expect(html.contains("<strong>bold</strong>"))
        }

        @Test @MainActor
        func exportingToPDFWritesARealPaginatedPDFFile() async throws {
            let (documentURL, tempRoot) = try makeFixture()
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let preferences =
                try Preferences(defaults: #require(UserDefaults(suiteName: "cli.e2e.\(UUID().uuidString)")))
            let arguments = try CLIExportArguments.parse([documentURL.path, "--format", "pdf"])
            let results = await ExportCLIRunner().run(arguments, preferences: preferences)

            #expect(results.count == 1)
            #expect(results[0].succeeded)
            let outputURL = try #require(results[0].outputURL)
            #expect(outputURL.lastPathComponent == "notes.pdf")
            let data = try Data(contentsOf: outputURL)
            #expect(data.starts(with: Data("%PDF".utf8)), "output must be a real PDF file")
        }

        @Test @MainActor
        func exportingABatchWithOutputDirRedirectsEveryOutputThere() async throws {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CLIRunnerE2ETest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let docA = tempRoot.appendingPathComponent("a.md")
            let docB = tempRoot.appendingPathComponent("b.md")
            try "# A".write(to: docA, atomically: true, encoding: .utf8)
            try "# B".write(to: docB, atomically: true, encoding: .utf8)
            let outputDir = tempRoot.appendingPathComponent("out")

            let arguments = try CLIExportArguments.parse([
                docA.path, docB.path, "--output-dir", outputDir.path,
            ])
            let results = await ExportCLIRunner().run(arguments)

            // swiftformat:disable:next preferKeyPath -- allSatisfy rethrows breaks #expect keypath resolution
            #expect(results.allSatisfy { $0.succeeded })
            #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("a.html").path))
            #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("b.html").path))
        }
    }
#endif
