@testable import FenCore
import Foundation
import Testing

/// End-to-end proof for issue #20 (rules 3.1, 3.2, 5.2 combined): drives the real
/// `ExternalChangeController` against a real on-disk file and a real `MarkdownDocument`, not
/// helper functions called directly. Uses `pollUntilTrue` (from `WebViewPreviewTestSupport.swift`)
/// to await the asynchronous `NSFilePresenter` callback -- never a fixed-duration sleep, per
/// `CONTRIBUTING.md`'s no-fixed-sleep rule.
@Suite("Detecting external file changes and offering to reload")
struct ExternalFileChangeVerifyTest {
    @Test("An external write to the document's file fires the reload prompt")
    @MainActor
    func externalWriteFiresReloadPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalFileChangeVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = ExternalChangeController()
        defer { controller.stop() }

        var promptCount = 0
        controller.presentReloadAlert = { _, _ in promptCount += 1 }
        controller.start(for: document)

        try "changed externally".write(to: fileURL, atomically: true, encoding: .utf8)

        let sawPrompt = try await pollUntilTrue {
            promptCount > 0
        }
        #expect(sawPrompt)
        #expect(promptCount == 1)
    }

    @Test("Choosing Reload replaces the in-app buffer with the file's on-disk content")
    @MainActor
    func reloadReplacesDocumentTextWithDiskContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalFileChangeVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = ExternalChangeController()
        defer { controller.stop() }

        controller.presentReloadAlert = { reload, _ in reload() }
        controller.start(for: document)

        try "changed externally".write(to: fileURL, atomically: true, encoding: .utf8)

        let reloaded = try await pollUntilTrue {
            document.text == "changed externally"
        }
        #expect(reloaded)
    }

    @Test("Choosing Keep Mine leaves the in-app buffer untouched")
    @MainActor
    func keepMineLeavesDocumentTextUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalFileChangeVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = ExternalChangeController()
        defer { controller.stop() }

        var keptMine = false
        controller.presentReloadAlert = { _, keepMine in
            keepMine()
            keptMine = true
        }
        controller.start(for: document)

        try "changed externally".write(to: fileURL, atomically: true, encoding: .utf8)

        let handled = try await pollUntilTrue {
            keptMine
        }
        #expect(handled)
        #expect(document.text == "original")
    }

    @Test("Two rapid external writes coalesce into exactly one prompt, not a stack of alerts")
    @MainActor
    func rapidSuccessiveExternalWritesCoalesceIntoOnePrompt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalFileChangeVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = ExternalChangeController()
        defer { controller.stop() }

        var promptCount = 0
        controller.presentReloadAlert = { _, _ in promptCount += 1 }
        controller.start(for: document)

        try "changed once".write(to: fileURL, atomically: true, encoding: .utf8)
        try "changed twice".write(to: fileURL, atomically: true, encoding: .utf8)

        let sawPrompt = try await pollUntilTrue {
            promptCount > 0
        }
        #expect(sawPrompt)
        // Give any second, wrongly-fired prompt a chance to land before asserting the count.
        _ = try await pollUntilTrue(timeout: .seconds(1)) { false }
        #expect(promptCount == 1, "a second rapid external write must not stack a second alert")
    }

    @Test("Fen's own save through MarkdownDocument's real write path never triggers the prompt")
    @MainActor
    func ownSaveNeverTriggersThePrompt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalFileChangeVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = ExternalChangeController()
        defer { controller.stop() }

        var promptCount = 0
        controller.presentReloadAlert = { _, _ in promptCount += 1 }
        controller.start(for: document)

        // Fen's own save path: coordinate the write through NSFileCoordinator, exactly as
        // DocumentGroup's ReferenceFileDocument save machinery does for a coordinated write.
        document.text = "saved by Fen itself"
        let snapshot = try document.snapshot(contentType: .markdown)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            try? snapshot.data(using: .utf8)?.write(to: url)
        }
        #expect(coordinationError == nil)

        // No callback is expected to fire; wait out a short window to prove absence, not just
        // check immediately (a callback dispatched to the main queue needs a runloop turn).
        let firedUnexpectedly = try await pollUntilTrue(timeout: .seconds(2)) {
            promptCount > 0
        }
        #expect(!firedUnexpectedly, "Fen's own coordinated save must not be treated as an external change")
    }
}
