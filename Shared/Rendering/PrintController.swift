import Foundation
#if os(macOS)
    import AppKit
#endif

#if os(macOS)
    /// Drives macOS's "Print…" command, calling `DocumentPDFExporter` for the render/compose work
    /// and `PDFRenderer.printDocument` to present the system print panel -- issue #32, mirrors
    /// `PDFExportController`. Holds no per-document state: every call is a pure function of its
    /// arguments, so two controller instances printing different documents never interact (rule
    /// 1.1).
    @MainActor
    @Observable
    public final class PrintController {
        /// Overridable by tests, matching `PDFExportController.presentErrorAlert` -- a real
        /// `NSAlert.runModal()` blocks indefinitely without an actual user click.
        public var presentErrorAlert: (_ message: String) -> Void = { message in
            let alert = NSAlert()
            alert.messageText = "Print Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }

        public init() {}

        /// Composes `document` into print-ready HTML via `DocumentPDFExporter` (the same pipeline
        /// #30's PDF export uses, issue #32 rule 2.2) and presents the system print panel for it.
        public func printDocument(document: MarkdownDocument, preferences: Preferences) {
            let html = DocumentPDFExporter().export(
                markdown: document.text, documentURL: document.fileURL, preferences: preferences
            )

            Task {
                do {
                    try await PDFRenderer().printDocument(
                        html: html, baseDirectory: document.fileURL?.deletingLastPathComponent()
                    )
                } catch {
                    presentErrorAlert(error.localizedDescription)
                }
            }
        }
    }
#endif
