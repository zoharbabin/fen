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

/// Opens the workspaces list as a sheet, from the launch screen or inside a document. UIKit
/// presents it, because on iPad the launch screen puts this button in a menu and a SwiftUI sheet
/// attached to the button goes away with the menu.
private struct WorkspacesButton: View {
    var body: some View {
        Button("Workspaces", systemImage: "folder.badge.gearshape") { WorkspacesSheet.present() }
    }
}

private struct WorkspacesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WorkspacesView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
    }

    @MainActor static func present() {
        #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            guard var top = scene?.keyWindow?.rootViewController else { return }
            while let presented = top.presentedViewController {
                top = presented
            }
            top.present(UIHostingController(rootView: WorkspacesSheet()), animated: true)
        #endif
    }
}
