import FenCore
import SwiftUI

@main
struct FenApp: App {
    init() {
        ShareTemporaryFiles.removeStale()
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
