import Foundation
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Owns one document's `ExternalFileChangeMonitor` and drives the reload/keep-mine/deletion
/// prompt in response to it (issue #20). Kept as its own `@Observable` class rather than plain
/// `@State` on `SplitEditorView` as first sketched in the Phase 1 spec, so tests can construct it
/// directly and override its alert-presentation closures -- the same testability tradeoff
/// `MarkdownTextView.Coordinator`'s `presentUnsavedDocumentAlert` already made for issue #18, but
/// `SplitEditorView` is a value-type `View` with no equivalent seam to hang an overridable closure
/// from.
@MainActor
@Observable
public final class ExternalChangeController {
    private var monitor: ExternalFileChangeMonitor?
    private weak var document: MarkdownDocument?
    private var isAlertShowing = false

    /// Overridden by `ExternalFileChangeVerifyTest` (issue #20, rule 5.2) so the reload/keep-mine
    /// choice can be driven headlessly -- a real `NSAlert.runModal()`/presented `UIAlertController`
    /// blocks indefinitely without an actual user click, confirmed empirically during issue #18's
    /// identical seam.
    public var presentReloadAlert: (_ reload: @escaping () -> Void, _ keepMine: @escaping () -> Void)
        -> Void = { reload, keepMine in
            #if os(macOS)
                let alert = NSAlert()
                alert.messageText = "File Changed on Disk"
                alert.informativeText = "This file was changed outside Fen. Reload it, or keep your current changes?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Reload")
                alert.addButton(withTitle: "Keep Mine")
                if alert.runModal() == .alertFirstButtonReturn {
                    reload()
                } else {
                    keepMine()
                }
            #else
                let alert = UIAlertController(
                    title: "File Changed on Disk",
                    message: "This file was changed outside Fen. Reload it, or keep your current changes?",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Reload", style: .default) { _ in reload() })
                alert.addAction(UIAlertAction(title: "Keep Mine", style: .cancel) { _ in keepMine() })
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)?
                    .rootViewController?
                    .present(alert, animated: true)
            #endif
        }

    /// Overridden by tests for the same reason as `presentReloadAlert`.
    public var presentDeletionAlert: () -> Void = {
        #if os(macOS)
            let alert = NSAlert()
            alert.messageText = "File Moved or Deleted"
            alert.informativeText = "This file was moved or deleted. Keep editing, or use File > Save As."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        #else
            let alert = UIAlertController(
                title: "File Moved or Deleted",
                message: "This file was moved or deleted. Keep editing, or use File > Save As.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController?
                .present(alert, animated: true)
        #endif
    }

    public init() {}

    /// Starts watching `document.fileURL` -- a no-op if the document has no on-disk file yet,
    /// matching issue #18's own precedent for the same nil-`fileURL` case: nothing to watch.
    /// Safe to call again after the URL changes (e.g. first save of a new document); tears down
    /// any previous monitor first.
    public func start(for document: MarkdownDocument) {
        stop()
        self.document = document
        guard let fileURL = document.fileURL else { return }
        monitor = ExternalFileChangeMonitor(
            fileURL: fileURL,
            onExternalChange: { [weak self] in self?.handleExternalChange() },
            onExternalDeletion: { [weak self] in self?.handleExternalDeletion() }
        )
    }

    public func stop() {
        monitor?.stop()
        monitor = nil
        document = nil
        isAlertShowing = false
    }

    private func handleExternalChange() {
        // Rule 3.2: NSFilePresenter's self-write exemption only applies to a coordinated write
        // made through this same presenter instance -- SwiftUI's DocumentGroup/ReferenceFileDocument
        // save machinery coordinates its own write independently and has no knowledge of this
        // presenter, so Fen's own save still fires this callback (confirmed empirically). Compare
        // the file's new content against the in-memory buffer instead: if they already match, this
        // change is Fen's own save (or a no-op external touch), not something to prompt about.
        guard let document, let fileURL = document.fileURL,
              let onDiskContent = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        guard onDiskContent.trimmingTrailingNewline != document.text.trimmingTrailingNewline else { return }

        // Rule 3.1: coalesce rapid successive external writes into the one alert already showing,
        // rather than stacking a second alert.
        guard !isAlertShowing else { return }
        isAlertShowing = true
        presentReloadAlert(
            { [weak self] in self?.reload() },
            { [weak self] in self?.keepMine() }
        )
    }

    private func handleExternalDeletion() {
        presentDeletionAlert()
    }

    private func reload() {
        isAlertShowing = false
        guard let document, let fileURL = document.fileURL,
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        document.text = contents
    }

    private func keepMine() {
        isAlertShowing = false
    }
}

private extension String {
    /// Fen's own save conditionally appends a trailing newline (`MarkdownDocument.snapshot`, per
    /// `Preferences.shared.editorEnsuresNewlineAtEndOfFile`) -- comparing with that one trailing
    /// newline stripped avoids treating Fen's own save as an external change on documents where
    /// that preference is on.
    var trimmingTrailingNewline: Substring {
        hasSuffix("\n") ? dropLast() : self[...]
    }
}
