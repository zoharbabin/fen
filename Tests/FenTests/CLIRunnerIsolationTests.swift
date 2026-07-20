@testable import FenCore
import Foundation
import Testing

// Harness gate 3 for issue #34, rule 1.1: two `ExportCLIRunner` calls running concurrently
// against two different batches never share or cross-contaminate their output -- `run` is a
// pure function of its arguments and the filesystem at call time, so this proves there's no
// static/shared mutable state backing it.
#if os(macOS)
    struct CLIRunnerIsolationTests {
        private func makeFixture(name: String) throws -> (inputURL: URL, tempRoot: URL) {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CLIRunnerIsolationTests-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let inputURL = tempRoot.appendingPathComponent("\(name).md")
            try "# \(name.capitalized) document".write(to: inputURL, atomically: true, encoding: .utf8)
            return (inputURL, tempRoot)
        }

        @Test @MainActor
        func twoRunsExportingDifferentBatchesConcurrentlyNeverCrossContaminate() async throws {
            let fixtureA = try makeFixture(name: "alpha")
            let fixtureB = try makeFixture(name: "beta")
            defer {
                try? FileManager.default.removeItem(at: fixtureA.tempRoot)
                try? FileManager.default.removeItem(at: fixtureB.tempRoot)
            }

            async let resultsA = try ExportCLIRunner().run(
                CLIExportArguments.parse([fixtureA.inputURL.path])
            )
            async let resultsB = try ExportCLIRunner().run(
                CLIExportArguments.parse([fixtureB.inputURL.path])
            )
            let (runA, runB) = try await (resultsA, resultsB)

            let htmlA = try String(contentsOf: #require(runA.first?.outputURL), encoding: .utf8)
            let htmlB = try String(contentsOf: #require(runB.first?.outputURL), encoding: .utf8)

            #expect(htmlA.contains("Alpha document"))
            #expect(htmlB.contains("Beta document"))
            #expect(!htmlA.contains("Beta"), "run A's output must never reference batch B's content")
            #expect(!htmlB.contains("Alpha"), "run B's output must never reference batch A's content")
        }
    }
#endif
