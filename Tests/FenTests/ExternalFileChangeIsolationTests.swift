@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #20, rule 1.1: two `ExternalFileChangeMonitor` instances watching two
/// independent files in one process never leak state into each other -- an external write to one
/// file must not fire the other's callback. Mirrors `ImagePasteIsolationTests.swift`'s two-instance
/// pattern, adapted to file-watch state instead of filesystem-numbering state.
struct ExternalFileChangeIsolationTests {
    @Test
    func externalWriteToOneFileNeverFiresTheOtherMonitorsCallback() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalFileChangeIsolationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileA = tempRoot.appendingPathComponent("a.md")
        let fileB = tempRoot.appendingPathComponent("b.md")
        try "original a".write(to: fileA, atomically: true, encoding: .utf8)
        try "original b".write(to: fileB, atomically: true, encoding: .utf8)

        actor Flags {
            var changedA = false
            var changedB = false
            func markA() {
                changedA = true
            }

            func markB() {
                changedB = true
            }
        }
        let flags = Flags()

        let monitorA = ExternalFileChangeMonitor(
            fileURL: fileA,
            onExternalChange: { Task { await flags.markA() } },
            onExternalDeletion: {}
        )
        let monitorB = ExternalFileChangeMonitor(
            fileURL: fileB,
            onExternalChange: { Task { await flags.markB() } },
            onExternalDeletion: {}
        )
        defer {
            monitorA.stop()
            monitorB.stop()
        }

        try "changed a".write(to: fileA, atomically: true, encoding: .utf8)

        let sawOnlyA = try await pollUntilTrue {
            await flags.changedA
        }
        #expect(sawOnlyA)
        #expect(await !flags.changedB, "External write to fileA must not fire fileB's monitor")
    }
}
