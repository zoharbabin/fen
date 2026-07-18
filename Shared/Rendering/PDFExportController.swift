import Foundation
#if os(macOS)
    import AppKit
#endif

#if os(macOS)
    /// Drives the macOS "Export to PDF…" save panel, calling `DocumentPDFExporter` for the
    /// render/compose/resolve work and `PDFRenderer` for the actual print-to-PDF write -- issue
    /// #30, mirrors `HTMLExportController`. Holds no per-document state: every call is a pure
    /// function of its arguments, so two controller instances exporting different documents
    /// never interact (rule 1.1).
    @MainActor
    @Observable
    public final class PDFExportController {
        /// Overridable by tests, matching `HTMLExportController.presentErrorAlert` -- a real
        /// `NSAlert.runModal()` blocks indefinitely without an actual user click.
        public var presentErrorAlert: (_ message: String) -> Void = { message in
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }

        public init() {}

        /// Presents the "Export to PDF…" save panel, then renders and writes the export --
        /// macOS's half of issue #30. There's only one PDF export flow (unlike #31's two HTML
        /// modes), so no accessory picker is needed.
        public func presentSavePanel(document: MarkdownDocument, preferences: Preferences) {
            let panel = NSSavePanel()
            panel.title = "Export to PDF"
            panel.nameFieldStringValue = "\(document.title ?? "Untitled").pdf"
            panel.allowedContentTypes = [.pdf]

            guard panel.runModal() == .OK, let destination = panel.url else { return }

            let html = DocumentPDFExporter().export(
                markdown: document.text, documentURL: document.fileURL, preferences: preferences
            )

            Task {
                do {
                    try await PDFRenderer().renderPDF(
                        html: html, baseDirectory: document.fileURL?.deletingLastPathComponent(), to: destination
                    )
                } catch {
                    presentErrorAlert(error.localizedDescription)
                }
            }
        }
    }
#endif
