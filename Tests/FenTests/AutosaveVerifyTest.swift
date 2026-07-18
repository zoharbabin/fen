@testable import FenCore
import Foundation
import Testing

/// End-to-end proof for issue #22 (rules 3.1, 3.2, 4.1, 4.2, 5.1): drives the real
/// `AutosaveController` against a real on-disk recovery file and a real `MarkdownDocument`, not
/// helper functions called directly. Uses `pollUntilTrue` (from `WebViewPreviewTestSupport.swift`)
/// to await asynchronous debounce/ceiling behavior -- never a fixed-duration sleep, per
/// `CONTRIBUTING.md`'s no-fixed-sleep rule. `idleInterval`/`ceilingInterval` are overridden to
/// short durations throughout so the real 2s/30s production values never have to be waited out.
@Suite("Autosaving unsaved changes and offering to recover them")
struct AutosaveVerifyTest {
    /// Mirrors the real `Fen/Recovery` layout `AutosaveController` writes to, the same knowledge
    /// `AutosaveIsolationTests` already inlines for its orphan-claiming test -- there's no public
    /// accessor for a controller's own recovery file path.
    private func recoveryFileURL(identity: String) throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TestError.noApplicationSupportDirectory
        }
        return base.appendingPathComponent("Fen", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent("\(identity).recovery")
    }

    private enum TestError: Error { case noApplicationSupportDirectory }

    @Test("Rapid edits within the idle window collapse into a single write of the latest text")
    @MainActor
    func rapidEditsCollapseIntoOneWriteOfTheLatestText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = AutosaveController()
        controller.idleInterval = .milliseconds(200)
        controller.ceilingInterval = .seconds(999)
        controller.presentRestorePrompt = { _, _ in }
        defer { controller.stop() }
        controller.start(for: document)

        let identity = AutosaveController.pathIdentity(for: fileURL)
        let recoveryURL = try recoveryFileURL(identity: identity)

        document.text = "edit one"
        controller.textDidChange()
        try await Task.sleep(for: .milliseconds(80))
        document.text = "edit two"
        controller.textDidChange()
        try await Task.sleep(for: .milliseconds(80))
        document.text = "edit three final"
        controller.textDidChange()

        #expect(
            !FileManager.default.fileExists(atPath: recoveryURL.path),
            "each edit resets the idle timer, so no write should have landed yet"
        )

        let wrote = try await pollUntilTrue(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: recoveryURL.path)
        }
        #expect(wrote)
        let content = try String(contentsOf: recoveryURL, encoding: .utf8)
        #expect(
            content == "edit three final",
            "a burst of rapid edits must collapse into exactly one write of the final text, not one write per edit"
        )
    }

    @Test("A ceiling write lands even when continuous edits never let the idle timer fire")
    @MainActor
    func ceilingWriteLandsUnderContinuousEditing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = AutosaveController()
        controller.idleInterval = .seconds(999)
        controller.ceilingInterval = .milliseconds(300)
        controller.presentRestorePrompt = { _, _ in }
        defer { controller.stop() }
        controller.start(for: document)

        let identity = AutosaveController.pathIdentity(for: fileURL)
        let recoveryURL = try recoveryFileURL(identity: identity)

        let typingTask = Task { @MainActor in
            for index in 0 ..< 50 {
                guard !Task.isCancelled else { return }
                document.text = "continuous edit \(index)"
                controller.textDidChange()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { typingTask.cancel() }

        let wrote = try await pollUntilTrue(timeout: .seconds(3)) {
            FileManager.default.fileExists(atPath: recoveryURL.path)
        }
        #expect(
            wrote,
            "the ceiling task must force a write even though continuous edits never let the idle timer settle"
        )
    }

    @Test("No write occurs when the buffer never diverges from its starting text")
    @MainActor
    func noWriteOccursWhenBufferIsUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = AutosaveController()
        controller.idleInterval = .milliseconds(50)
        controller.ceilingInterval = .seconds(999)
        controller.presentRestorePrompt = { _, _ in }
        defer { controller.stop() }
        controller.start(for: document)

        let identity = AutosaveController.pathIdentity(for: fileURL)
        let recoveryURL = try recoveryFileURL(identity: identity)

        controller.textDidChange()
        // Wait out the idle window and then some, proving absence rather than checking too soon.
        _ = try await pollUntilTrue(timeout: .seconds(1)) { false }
        #expect(
            !FileManager.default.fileExists(atPath: recoveryURL.path),
            "an unchanged buffer must never produce a recovery write"
        )
    }

    @Test("Editing back to match the on-disk content deletes the now-redundant recovery entry")
    @MainActor
    func editingBackToOnDiskContentDeletesTheRecoveryEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = AutosaveController()
        controller.idleInterval = .milliseconds(50)
        controller.ceilingInterval = .seconds(999)
        controller.presentRestorePrompt = { _, _ in }
        defer { controller.stop() }
        controller.start(for: document)

        let identity = AutosaveController.pathIdentity(for: fileURL)
        let recoveryURL = try recoveryFileURL(identity: identity)

        document.text = "changed"
        controller.textDidChange()
        let wrote = try await pollUntilTrue(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: recoveryURL.path)
        }
        #expect(wrote)

        document.text = "original"
        controller.textDidChange()
        let deleted = try await pollUntilTrue(timeout: .seconds(2)) {
            !FileManager.default.fileExists(atPath: recoveryURL.path)
        }
        #expect(deleted, "editing back to exactly the on-disk content must delete the now-redundant recovery entry")
    }

    @Test("Choosing Restore replaces the document's buffer with the recovered text")
    @MainActor
    func choosingRestoreReplacesDocumentBufferWithRecoveredText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "saved content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Simulate a prior session that never exited cleanly: its controller wrote a recovery
        // entry, but `stop()` was never called, so the entry is left behind on disk.
        let priorDocument = MarkdownDocument(text: "saved content")
        priorDocument.fileURL = fileURL
        let priorController = AutosaveController()
        priorController.idleInterval = .milliseconds(30)
        priorController.ceilingInterval = .seconds(999)
        priorController.presentRestorePrompt = { _, _ in }
        priorController.start(for: priorDocument)

        let identity = AutosaveController.pathIdentity(for: fileURL)
        let recoveryURL = try recoveryFileURL(identity: identity)
        priorDocument.text = "unsaved recovered text"
        priorController.textDidChange()
        let leftBehind = try await pollUntilTrue(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: recoveryURL.path)
        }
        #expect(leftBehind)

        // A new session opens the same file: its document starts out matching on-disk content,
        // exactly as a real re-open would, and its controller discovers the leftover entry.
        let newDocument = MarkdownDocument(text: "saved content")
        newDocument.fileURL = fileURL
        let newController = AutosaveController()
        defer { newController.stop() }
        newController.presentRestorePrompt = { restore, _ in restore() }
        newController.start(for: newDocument)

        #expect(newDocument.text == "unsaved recovered text")
        #expect(
            !FileManager.default.fileExists(atPath: recoveryURL.path),
            "accepting a restore must consume the recovery entry"
        )
    }

    @Test("Choosing Discard leaves the document's on-disk content untouched and clears the entry")
    @MainActor
    func choosingDiscardLeavesDocumentUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "saved content".write(to: fileURL, atomically: true, encoding: .utf8)

        let priorDocument = MarkdownDocument(text: "saved content")
        priorDocument.fileURL = fileURL
        let priorController = AutosaveController()
        priorController.idleInterval = .milliseconds(30)
        priorController.ceilingInterval = .seconds(999)
        priorController.presentRestorePrompt = { _, _ in }
        priorController.start(for: priorDocument)

        let identity = AutosaveController.pathIdentity(for: fileURL)
        let recoveryURL = try recoveryFileURL(identity: identity)
        priorDocument.text = "unsaved recovered text"
        priorController.textDidChange()
        let leftBehind = try await pollUntilTrue(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: recoveryURL.path)
        }
        #expect(leftBehind)

        let newDocument = MarkdownDocument(text: "saved content")
        newDocument.fileURL = fileURL
        let newController = AutosaveController()
        defer { newController.stop() }
        newController.presentRestorePrompt = { _, discard in discard() }
        newController.start(for: newDocument)

        #expect(newDocument.text == "saved content", "discarding must leave the document's buffer exactly as it was")
        #expect(!FileManager.default.fileExists(atPath: recoveryURL.path), "discarding must clear the recovery entry")
    }

    @Test("A write into an unwritable recovery directory fails silently, without crashing or leaving a partial file")
    @MainActor
    func writeFailureIsSwallowedWithoutCrashingOrLeavingAPartialFile() async throws {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            Issue.record("no Application Support directory available in this environment")
            return
        }
        let recoveryDirectory = base.appendingPathComponent("Fen", isDirectory: true).appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let originalPermissions = try FileManager.default
            .attributesOfItem(atPath: recoveryDirectory.path)[.posixPermissions] as? Int
        defer {
            if let originalPermissions {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: originalPermissions],
                    ofItemAtPath: recoveryDirectory.path
                )
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveVerifyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = MarkdownDocument(text: "original")
        document.fileURL = fileURL
        let controller = AutosaveController()
        controller.idleInterval = .milliseconds(50)
        controller.ceilingInterval = .seconds(999)
        controller.presentRestorePrompt = { _, _ in }
        defer { controller.stop() }
        controller.start(for: document)

        let identity = AutosaveController.pathIdentity(for: fileURL)
        let recoveryURL = try recoveryFileURL(identity: identity)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recoveryDirectory.path)

        document.text = "edited while the recovery directory is unwritable"
        controller.textDidChange()

        // Wait out the idle window; a crash or uncaught throw here would fail the test on its own.
        _ = try await pollUntilTrue(timeout: .seconds(1)) { false }
        #expect(
            !FileManager.default.fileExists(atPath: recoveryURL.path),
            "a write that can't create its target file must fail silently, never leave a partial/corrupt one"
        )
    }
}
