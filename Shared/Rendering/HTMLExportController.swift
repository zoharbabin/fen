import Foundation
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Choice presented to the user before an HTML export (issue #31) -- not persisted to
/// `Preferences`, since it's a one-off decision per export rather than a standing setting.
public enum HTMLExportChoice: String, CaseIterable, Sendable {
    case selfContained = "Self-Contained (single file)"
    case linkedAssets = "Linked Assets (separate folder)"
}

/// Drives the macOS "Export to HTML…" save panel, calling `DocumentHTMLExporter` for the actual
/// render/compose/resolve work and owning only the platform save-panel/file-write mechanics
/// (issue #31, rule 5.1 -- one write implementation shared by both export modes). Holds no
/// per-document state: every call is a pure function of its arguments, so two controller
/// instances exporting different documents never interact (rule 1.1).
@MainActor
@Observable
public final class HTMLExportController {
    /// Overridable by tests, for the same reason `ExternalChangeController.presentReloadAlert`
    /// is -- a real `NSAlert.runModal()`/presented `UIAlertController` blocks indefinitely
    /// without an actual user click.
    public var presentErrorAlert: (_ message: String) -> Void = { message in
        #if os(macOS)
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        #else
            let alert = UIAlertController(title: "Export Failed", message: message, preferredStyle: .alert)
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

    /// Writes `result.html` to `destination` and, for `linkedAssets` mode, copies each resolved
    /// asset alongside it -- the write step both platforms share once `DocumentHTMLExporter` has
    /// already rendered and resolved the export in memory.
    public func write(_ result: DocumentHTMLExporter.Result, to destination: URL) throws {
        try result.html.write(to: destination, atomically: true, encoding: .utf8)
        let destinationDirectory = destination.deletingLastPathComponent()
        for asset in result.assets {
            let assetDestination = destinationDirectory.appendingPathComponent(asset.relativePath)
            try FileManager.default.createDirectory(
                at: assetDestination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: assetDestination.path) {
                try FileManager.default.removeItem(at: assetDestination)
            }
            try FileManager.default.copyItem(at: asset.sourceFileURL, to: assetDestination)
        }
    }

    #if os(macOS)
        /// Presents the "Export to HTML…" save panel with a self-contained/linked-assets
        /// accessory choice, then renders, resolves, and writes the export -- macOS's half of
        /// issue #31. Runs the panel modally, matching the existing synchronous `NSAlert.runModal`
        /// precedent used elsewhere in this codebase for user-facing choices.
        public func presentSavePanel(document: MarkdownDocument, preferences: Preferences) {
            let panel = NSSavePanel()
            panel.title = "Export to HTML"
            panel.nameFieldStringValue = "\(document.title ?? "Untitled").html"
            panel.allowedContentTypes = [.html]

            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
            picker.addItems(withTitles: HTMLExportChoice.allCases.map(\.rawValue))
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 38))
            picker.frame.origin = NSPoint(x: 10, y: 6)
            accessory.addSubview(picker)
            panel.accessoryView = accessory

            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let choice = HTMLExportChoice.allCases.first { $0.rawValue == picker.titleOfSelectedItem }
                ?? .selfContained

            let mode: ExportAssetMode = choice == .selfContained
                ? .selfContained
                : .linkedAssets(exportBaseName: destination.deletingPathExtension().lastPathComponent)

            let result = DocumentHTMLExporter().export(
                markdown: document.text, documentURL: document.fileURL, preferences: preferences, mode: mode
            )
            do {
                try write(result, to: destination)
            } catch {
                presentErrorAlert(error.localizedDescription)
            }
        }
    #endif
}
