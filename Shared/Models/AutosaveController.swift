import CryptoKit
import Foundation
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Persists a document's unsaved buffer to a recovery file and offers to restore it the next
/// time that document is opened after an unclean exit (issue #22). Keyed off content
/// divergence rather than a crash/pid-liveness signal: a recovery entry is written whenever the
/// in-memory buffer differs from what's on disk, and deleted the moment they match again --
/// whether because the user saved, or because a restore was accepted or declined. That means no
/// `NSApplicationDelegate`/quit-hook wiring is needed at all: if the app disappears uncleanly, a
/// recovery entry is simply left behind for the next launch to find.
///
/// Follows `ExternalChangeController`'s shape (`@Observable`, `start(for:)`/`stop()`, an
/// overridable alert-presentation closure) for the same testability reasons that controller
/// documents.
@MainActor
@Observable
public final class AutosaveController {
    private weak var document: MarkdownDocument?
    private var identity: String?
    private var idleTask: Task<Void, Never>?
    private var ceilingTask: Task<Void, Never>?
    private var lastWrittenText: String?

    /// Overridable by tests, for the same testability reason `presentRestorePrompt` is -- lets
    /// `AutosaveVerifyTest` prove the idle-debounce-with-ceiling behavior (rule 4.1) in a
    /// reasonable amount of wall-clock time instead of waiting out the real 2s/30s intervals.
    var idleInterval: Duration = .seconds(2)
    var ceilingInterval: Duration = .seconds(30)

    /// Guards against two blank documents opened at the same moment both claiming (and both
    /// prompting to restore) the same orphaned untitled recovery entry. Tracks identity only,
    /// never document content -- released in `stop()`, since it exists purely to arbitrate a
    /// same-instant race, not to remember anything across a document's lifetime.
    private static var claimedOrphanIdentities: Set<String> = []

    /// Overridden by tests, for the same reason `ExternalChangeController.presentReloadAlert` is.
    public var presentRestorePrompt: (_ restore: @escaping () -> Void, _ discard: @escaping () -> Void)
        -> Void = { restore, discard in
            #if os(macOS)
                let alert = NSAlert()
                alert.messageText = "Recover Unsaved Changes?"
                alert.informativeText = "Fen didn't close cleanly last time. Restore the unsaved changes, or discard them?"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Restore")
                alert.addButton(withTitle: "Discard")
                if alert.runModal() == .alertFirstButtonReturn {
                    restore()
                } else {
                    discard()
                }
            #else
                let alert = UIAlertController(
                    title: "Recover Unsaved Changes?",
                    message: "Fen didn't close cleanly last time. Restore the unsaved changes, or discard them?",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Restore", style: .default) { _ in restore() })
                alert.addAction(UIAlertAction(title: "Discard", style: .cancel) { _ in discard() })
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)?
                    .rootViewController?
                    .present(alert, animated: true)
            #endif
        }

    public init() {}

    /// Starts autosaving `document` and checks for a leftover recovery entry from an unclean
    /// exit. Safe to call again after `fileURL` changes (e.g. a new document's first save) --
    /// tears down the previous identity first.
    public func start(for document: MarkdownDocument) {
        stop()
        self.document = document
        if let fileURL = document.fileURL {
            let identity = Self.pathIdentity(for: fileURL)
            self.identity = identity
            checkForSavedDocumentRecovery(identity: identity, document: document)
        } else {
            let identity = Self.claimOrphanOrNewIdentity()
            self.identity = identity
            checkForUntitledDocumentRecovery(identity: identity, document: document)
        }
        lastWrittenText = document.text
        armCeilingTask()
    }

    public func stop() {
        idleTask?.cancel()
        idleTask = nil
        ceilingTask?.cancel()
        ceilingTask = nil
        if let identity {
            Self.claimedOrphanIdentities.remove(identity)
            deleteRecoveryFileIfRedundant(identity: identity)
        }
        document = nil
        identity = nil
        lastWrittenText = nil
    }

    /// Call on every edit. Debounced to `idleInterval` after the last edit; a separate ceiling
    /// task (armed once in `start`) guarantees a write at least every `ceilingInterval` even
    /// under continuous, uninterrupted typing that never lets the idle timer fire.
    public func textDidChange() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            guard let idleInterval = self?.idleInterval else { return }
            try? await Task.sleep(for: idleInterval)
            guard !Task.isCancelled else { return }
            self?.writeRecoveryIfNeeded()
        }
    }

    private func armCeilingTask() {
        ceilingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let ceilingInterval = self?.ceilingInterval else { return }
                try? await Task.sleep(for: ceilingInterval)
                guard !Task.isCancelled else { return }
                self?.writeRecoveryIfNeeded()
            }
        }
    }

    private func writeRecoveryIfNeeded() {
        guard let document, let identity else { return }
        let text = document.text
        guard text != lastWrittenText else { return }
        if let fileURL = document.fileURL,
           let onDiskContent = try? String(contentsOf: fileURL, encoding: .utf8),
           onDiskContent.trimmingTrailingNewline == text.trimmingTrailingNewline {
            Self.deleteRecoveryFile(identity: identity)
            lastWrittenText = text
            return
        }
        Self.writeRecoveryFile(identity: identity, text: text)
        lastWrittenText = text
    }

    private func deleteRecoveryFileIfRedundant(identity: String) {
        guard let document else { return }
        guard let recoveryText = Self.readRecoveryFile(identity: identity) else { return }
        let currentText = document.text
        if let fileURL = document.fileURL,
           let onDiskContent = try? String(contentsOf: fileURL, encoding: .utf8),
           onDiskContent.trimmingTrailingNewline == currentText.trimmingTrailingNewline {
            Self.deleteRecoveryFile(identity: identity)
        } else if recoveryText.trimmingTrailingNewline == currentText.trimmingTrailingNewline {
            Self.deleteRecoveryFile(identity: identity)
        }
    }

    private func checkForSavedDocumentRecovery(identity: String, document: MarkdownDocument) {
        guard let recoveryText = Self.readRecoveryFile(identity: identity) else { return }
        guard recoveryText.trimmingTrailingNewline != document.text.trimmingTrailingNewline else {
            Self.deleteRecoveryFile(identity: identity)
            return
        }
        presentRestorePrompt(
            { [weak document] in
                document?.text = recoveryText
                Self.deleteRecoveryFile(identity: identity)
            },
            { Self.deleteRecoveryFile(identity: identity) }
        )
    }

    private func checkForUntitledDocumentRecovery(identity: String, document: MarkdownDocument) {
        guard let recoveryText = Self.readRecoveryFile(identity: identity), !recoveryText.isEmpty else { return }
        presentRestorePrompt(
            { [weak document] in
                document?.text = recoveryText
                Self.deleteRecoveryFile(identity: identity)
            },
            { Self.deleteRecoveryFile(identity: identity) }
        )
    }

    // MARK: - Identity and storage

    private static func recoveryDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("Fen", isDirectory: true).appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A stable identity for a saved document's recovery entry: a SHA-256 hash of its resolved
    /// absolute path, taken *after* symlink resolution -- resolving before hashing (rather than
    /// hashing the unresolved path) is the same ordering `ImagePasteInsertionTests` proved matters
    /// for issue #18's sidecar-write guard, so two paths that resolve to the same real file always
    /// share one recovery entry.
    static func pathIdentity(for fileURL: URL) -> String {
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(resolved.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "path-\(hex)"
    }

    private static func claimOrphanOrNewIdentity() -> String {
        if let directory = recoveryDirectory(),
           let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let orphan = contents
                .map { $0.deletingPathExtension().lastPathComponent }
                .filter { $0.hasPrefix("untitled-") && !claimedOrphanIdentities.contains($0) }
                .min()
            if let orphan {
                claimedOrphanIdentities.insert(orphan)
                return orphan
            }
        }
        let identity = "untitled-\(UUID().uuidString)"
        claimedOrphanIdentities.insert(identity)
        return identity
    }

    private static func recoveryFileURL(identity: String) -> URL? {
        recoveryDirectory()?.appendingPathComponent("\(identity).recovery")
    }

    private static func readRecoveryFile(identity: String) -> String? {
        guard let url = recoveryFileURL(identity: identity) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func writeRecoveryFile(identity: String, text: String) {
        guard let url = recoveryFileURL(identity: identity) else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func deleteRecoveryFile(identity: String) {
        guard let url = recoveryFileURL(identity: identity) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private extension String {
    /// Same trailing-newline normalization `ExternalChangeController` uses, for the same reason:
    /// `MarkdownDocument.snapshot` conditionally appends one, so a naive comparison could treat a
    /// preference-driven newline as a real content difference.
    var trimmingTrailingNewline: Substring {
        hasSuffix("\n") ? dropLast() : self[...]
    }
}
