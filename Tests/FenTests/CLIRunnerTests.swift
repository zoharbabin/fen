@testable import FenCore
import Foundation
import Testing

// Proves issue #34's argument-parsing and resiliency rules (3.1, 3.2): a bad input in a batch
// fails only that file rather than aborting the rest, and an unwritable output directory
// surfaces a per-file error rather than crashing.
#if os(macOS)
    struct CLIRunnerTests {
        @Test func parsingRequiresAtLeastOneInputFile() {
            #expect(throws: CLIExportArguments.ParseError.noInputFiles) {
                try CLIExportArguments.parse(["--format", "html"])
            }
        }

        @Test func parsingRejectsAnUnknownFormat() {
            #expect(throws: CLIExportArguments.ParseError.unknownFormat("xml")) {
                try CLIExportArguments.parse(["doc.md", "--format", "xml"])
            }
        }

        @Test func parsingRejectsLinkedAssetsWithPDFFormat() {
            #expect(throws: CLIExportArguments.ParseError.linkedAssetsRequiresHTML) {
                try CLIExportArguments.parse(["doc.md", "--format", "pdf", "--linked-assets"])
            }
        }

        @Test func parsingDefaultsToHTMLFormatAndNoOutputDirectory() throws {
            let parsed = try CLIExportArguments.parse(["doc.md"])
            #expect(parsed.format == .html)
            #expect(parsed.outputDirectory == nil)
            #expect(parsed.linkedAssets == false)
        }

        @Test func parsingCollectsMultipleInputFilesAndOptions() throws {
            let parsed = try CLIExportArguments.parse([
                "a.md", "b.md", "--format", "pdf", "--output-dir", "/tmp/out",
            ])
            #expect(parsed.inputPaths == ["a.md", "b.md"])
            #expect(parsed.format == .pdf)
            #expect(parsed.outputDirectory == "/tmp/out")
        }

        @Test @MainActor
        func oneMissingFileInABatchFailsOnlyThatFileAndTheRestStillExport() async throws {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CLIRunnerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let goodA = tempRoot.appendingPathComponent("a.md")
            let missing = tempRoot.appendingPathComponent("missing.md")
            let goodB = tempRoot.appendingPathComponent("b.md")
            try "# A".write(to: goodA, atomically: true, encoding: .utf8)
            try "# B".write(to: goodB, atomically: true, encoding: .utf8)

            var reportedErrors: [String] = []
            let arguments = try CLIExportArguments.parse([goodA.path, missing.path, goodB.path])
            let results = await ExportCLIRunner().run(arguments) { reportedErrors.append($0) }

            #expect(results.count == 3)
            #expect(results[0].succeeded)
            #expect(!results[1].succeeded)
            #expect(results[2].succeeded)
            #expect(reportedErrors.count == 1)
            #expect(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("a.html").path))
            #expect(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("b.html").path))
        }

        @Test @MainActor
        func anUnwritableOutputDirectorySurfacesAPerFileErrorRatherThanCrashing() async throws {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CLIRunnerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempRoot.path)
                try? FileManager.default.removeItem(at: tempRoot)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempRoot.path)

            // The read source lives outside the locked-down directory -- only the destination is
            // unwritable, isolating the assertion to the write failure this test targets.
            let sourceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CLIRunnerTests-source-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sourceRoot) }
            let sourceInput = sourceRoot.appendingPathComponent("doc.md")
            try "# Doc".write(to: sourceInput, atomically: true, encoding: .utf8)

            var reportedErrors: [String] = []
            let arguments = try CLIExportArguments.parse([sourceInput.path, "--output-dir", tempRoot.path])
            let results = await ExportCLIRunner().run(arguments) { reportedErrors.append($0) }

            #expect(results.count == 1)
            #expect(!results[0].succeeded)
            #expect(reportedErrors.count == 1)
        }
    }
#endif
