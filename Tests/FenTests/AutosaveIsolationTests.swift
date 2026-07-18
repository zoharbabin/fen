@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #22, rules 1.1 and 1.2: two `AutosaveController` instances watching
/// two independent documents never leak state into each other, and the orphan-claiming
/// arbitration for untitled documents tracks identity only, never content.
struct AutosaveIsolationTests {
    @Test @MainActor
    func recoveryWritesForTwoDocumentsNeverCrossOver() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveIsolationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileA = tempRoot.appendingPathComponent("a.md")
        let fileB = tempRoot.appendingPathComponent("b.md")
        try "original a".write(to: fileA, atomically: true, encoding: .utf8)
        try "original b".write(to: fileB, atomically: true, encoding: .utf8)

        let documentA = MarkdownDocument(text: "original a")
        documentA.fileURL = fileA
        let documentB = MarkdownDocument(text: "original b")
        documentB.fileURL = fileB

        let controllerA = AutosaveController()
        let controllerB = AutosaveController()
        defer {
            controllerA.stop()
            controllerB.stop()
        }
        controllerA.presentRestorePrompt = { _, _ in }
        controllerB.presentRestorePrompt = { _, _ in }
        controllerA.start(for: documentA)
        controllerB.start(for: documentB)

        let identityA = AutosaveController.pathIdentity(for: fileA)
        let identityB = AutosaveController.pathIdentity(for: fileB)
        #expect(identityA != identityB, "two distinct files must never share a recovery identity")
    }

    @Test @MainActor
    func twoUntitledDocumentsOpenedAtOnceNeverClaimTheSameOrphan() async throws {
        // Plants one leftover orphaned untitled recovery entry on disk, exactly as an unclean
        // exit of a prior blank document would leave behind, then starts two brand-new blank
        // documents' controllers back to back and proves at most one of them claims (and
        // offers to restore) that orphan -- the one deliberate, scoped exception to per-instance
        // isolation (rule 1.2).
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            Issue.record("no Application Support directory available in this environment")
            return
        }
        let recoveryDirectory = base.appendingPathComponent("Fen", isDirectory: true).appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        // Clear any untitled-* leftovers from other test runs sharing this real Application
        // Support directory, so this test's "exactly one orphan exists" premise holds.
        let preexisting = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        )
        for url in preexisting where url.lastPathComponent.hasPrefix("untitled-") {
            try? FileManager.default.removeItem(at: url)
        }
        let orphanIdentity = "untitled-\(UUID().uuidString)"
        let orphanURL = recoveryDirectory.appendingPathComponent("\(orphanIdentity).recovery")
        try "leftover unsaved text".write(to: orphanURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: orphanURL) }

        var restoredX = false
        var restoredY = false

        let documentX = MarkdownDocument(text: "")
        let controllerX = AutosaveController()
        defer { controllerX.stop() }
        controllerX.presentRestorePrompt = { restore, _ in
            restore()
            restoredX = true
        }
        controllerX.start(for: documentX)

        let documentY = MarkdownDocument(text: "")
        let controllerY = AutosaveController()
        defer { controllerY.stop() }
        controllerY.presentRestorePrompt = { restore, _ in
            restore()
            restoredY = true
        }
        controllerY.start(for: documentY)

        // `checkForUntitledDocumentRecovery` defers `presentRestorePrompt` to the next run loop
        // turn (see AutosaveController's doc comment), so wait for one of the two deferred
        // callbacks to have actually fired before asserting on which one claimed the orphan.
        _ = try await pollUntilTrue(timeout: .seconds(2)) { restoredX || restoredY }

        #expect(!(restoredX && restoredY), "two blank documents must never both restore from the same orphan")
        #expect(
            restoredX != restoredY,
            "exactly one of the two new blank documents should claim the sole leftover orphan"
        )
    }
}
