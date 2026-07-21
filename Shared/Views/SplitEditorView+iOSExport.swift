import SwiftUI
#if os(iOS)
    import UIKit
#endif

#if os(iOS)
    /// iOS's export/print/copy actions (issues #30-#33), split from `SplitEditorView.swift` to
    /// keep that file under swiftlint's file/type length limits.
    extension SplitEditorView {
        /// Renders and resolves the export up front (issue #31) -- `.fileExporter` needs a
        /// fully-prepared `FileDocument` before the user picks a destination, unlike macOS's
        /// `NSSavePanel` which can pass a chosen directory into the write step.
        func presentHTMLExporter(choice: HTMLExportChoice) {
            let baseName = document.title ?? "Untitled"
            let mode: ExportAssetMode = choice == .selfContained
                ? .selfContained
                : .linkedAssets(exportBaseName: baseName)

            let result = DocumentHTMLExporter().export(
                markdown: document.text, documentURL: document.fileURL, preferences: preferences, mode: mode
            )
            let isDirectory = choice == .linkedAssets
            htmlExportDocument = HTMLExportDocument(result: result, isDirectory: isDirectory)
            htmlExportContentType = isDirectory ? .folder : .html
            htmlExportFilename = isDirectory ? baseName : "\(baseName).html"
            isHTMLExportPresented = true
        }

        /// Renders and resolves the export up front (issue #30), same constraint as
        /// `presentHTMLExporter` -- `.fileExporter` needs a fully-prepared `FileDocument` before
        /// the user picks a destination. Rendering to PDF takes longer than composing HTML, so
        /// this runs off the main actor's synchronous path via `Task`, with `isPDFExporting`
        /// disabling the menu button until it finishes.
        func presentPDFExporter() {
            let baseName = document.title ?? "Untitled"
            let markdown = document.text
            let fileURL = document.fileURL
            isPDFExporting = true
            Task {
                let html = DocumentPDFExporter().export(
                    markdown: markdown,
                    documentURL: fileURL,
                    preferences: preferences
                )
                do {
                    let data = try await PDFRenderer().renderPDFData(
                        html: html, baseDirectory: fileURL?.deletingLastPathComponent()
                    )
                    pdfExportDocument = PDFExportDocument(data: data)
                    pdfExportFilename = "\(baseName).pdf"
                    isPDFExportPresented = true
                } catch {
                    // No alert-presentation hook exists for iOS in this view yet; failure simply
                    // leaves the export sheet unpresented, matching how a cancelled/failed
                    // `.fileExporter` call already behaves with no document set.
                }
                isPDFExporting = false
            }
        }

        /// Presents the system print sheet -- iOS's half of issue #32. Composes via
        /// `DocumentPDFExporter` (the same pipeline #30's PDF export uses, rule 2.2), then builds
        /// a `UIPrintInteractionController` from `PDFRenderer.makePrintInteractionController`.
        /// Anchors to `printAnchorView`'s frame on `.regular` horizontal size class (iPad), where
        /// `present(animated:completionHandler:)` alone would log a warning and may not present a
        /// popover; falls back to that plain call on `.compact` (iPhone), where no anchor is
        /// required.
        func presentPrint() {
            let baseName = document.title ?? "Untitled"
            let markdown = document.text
            let fileURL = document.fileURL
            isPrinting = true
            Task {
                let html = DocumentPDFExporter().export(
                    markdown: markdown,
                    documentURL: fileURL,
                    preferences: preferences
                )
                do {
                    let controller = try await PDFRenderer().makePrintInteractionController(
                        html: html,
                        baseDirectory: fileURL?.deletingLastPathComponent(),
                        documentName: baseName
                    )
                    if horizontalSizeClass == .regular, let anchorView = printAnchorView {
                        let anchorRect = anchorView.convert(anchorView.bounds, to: nil)
                        controller.present(from: anchorRect, in: anchorView, animated: true) { _, _, _ in }
                    } else {
                        controller.present(animated: true) { _, _, _ in }
                    }
                } catch {
                    // No alert-presentation hook exists for iOS printing yet; failure simply
                    // leaves the print sheet unpresented, matching how a failed PDF export
                    // already behaves in `presentPDFExporter` above.
                }
                isPrinting = false
            }
        }

        /// iOS's half of "Copy as Raw HTML" (issue #33) -- synchronous, unlike
        /// `presentPDFExporter`/`presentPrint`, since `ClipboardExporter.copyAsRawHTML` composes
        /// self-contained HTML and writes it directly to `UIPasteboard.general` with no PDF
        /// render or system UI in the way.
        func copyAsRawHTML() {
            ClipboardExporter().copyAsRawHTML(
                markdown: document.text, documentURL: document.fileURL, preferences: preferences
            )
        }

        /// iOS's half of "Copy as Rich Text Formatted" -- mirrors `copyAsRawHTML`.
        func copyAsRichTextFormatted() {
            ClipboardExporter().copyAsRichTextFormatted(
                markdown: document.text, documentURL: document.fileURL, preferences: preferences
            )
        }
    }
#endif
