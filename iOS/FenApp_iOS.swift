import FenCore
import SwiftUI
#if os(iOS)
    import UIKit
#endif

@main
struct FenApp: App {
    init() {
        ShareTemporaryFiles.removeStale()
        ScheduledEnrichment.launch()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument.makeNew() }, editor: { file in
            SplitEditorView(document: file.document)
                .toolbarRole(.editor)
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) { WorkspacesButton() }
                }
                .onAppear { file.document.fileURL = file.fileURL }
                .onChange(of: file.fileURL) { _, newValue in file.document.fileURL = newValue }
        })
        .commands {
            FormattingCommands()
            ViewCommands()
            CommandGroup(after: .printItem) {
                Button("Print…") {
                    NotificationCenter.default.post(name: .printDocument, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
            }
        }

        #if os(iOS)
            DocumentGroupLaunchScene("Fen") {
                NewDocumentButton("New Document")
                // Text from another app (a Safari selection, Notes) cannot open as a file, so copy
                // it and make a document from the clipboard (issue #43).
                NewDocumentButton("New from Clipboard", for: MarkdownDocument.self) {
                    try await MainActor.run { try SharedTextImport.document(from: UIPasteboard.general.string) }
                }
                WorkspacesButton()
            }
        #endif
    }
}

/// Opens the workspaces list as a sheet, from the launch screen or inside a document.
private struct WorkspacesButton: View {
    @State private var showing = false

    var body: some View {
        Button("Workspaces", systemImage: "folder.badge.gearshape") { showing = true }
            .sheet(isPresented: $showing) {
                NavigationStack {
                    WorkspacesView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Done") { showing = false } }
                        }
                }
            }
    }
}
