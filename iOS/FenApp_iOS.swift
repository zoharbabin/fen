import FenCore
import SwiftUI
#if os(iOS)
    import UIKit
#endif

@main
struct FenApp: App {
    init() {
        ShareTemporaryFiles.removeStale()
        SharedTextInbox.standard?.purge()
        #if os(iOS)
            SharedNotes.importWaiting()
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { SharedNotes.importWaiting() } }
        #endif
        ScheduledEnrichment.launch()
        #if DEBUG
            DeviceSelfTest.runIfRequested()
        #endif
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
                ClipboardNoteButton()
                WorkspacesButton()
            }
        #endif
    }
}

#if os(iOS)
    /// Text shared to Fen from another app's share sheet waits in the App Group inbox (issue #43).
    /// Fen turns each item into a `.md` note in its Documents folder, so it shows in the document list
    /// like any other note. The launch screen's "New Document" button can't do this: on iOS 27 it ignores
    /// the closure it is given and creates a blank note.
    @MainActor private enum SharedNotes {
        static func importWaiting() {
            guard let inbox = SharedTextInbox.standard,
                  let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            inbox.importAll(into: folder)
        }
    }
#endif

#if os(iOS)
    /// Saves the copied text as a note in Fen's Documents folder, where the document list shows it.
    private struct ClipboardNoteButton: View {
        @State private var message: String?

        var body: some View {
            Button("New from Clipboard", systemImage: "doc.on.clipboard") {
                do {
                    let folder = try FileManager.default.url(
                        for: .documentDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: true
                    )
                    let saved = try SharedTextImport.saveNote(from: UIPasteboard.general.string, into: folder)
                    message = saved.map { "Saved \($0.lastPathComponent) to your notes." }
                        ?? "The clipboard has no text."
                } catch {
                    message = error.localizedDescription
                }
            }
            .alert("New from Clipboard", isPresented: Binding(get: { message != nil }, set: { _ in message = nil })) {
                Button("OK") {}
            } message: {
                Text(message ?? "")
            }
        }
    }
#endif

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
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// On a phone the list needs its own navigation bar, which a `NavigationStack` around it would hide,
    /// with the Add button. On iPad the stack carries the Done button.
    var body: some View {
        if sizeClass == .compact {
            WorkspacesView { dismiss() }
        } else {
            NavigationStack {
                WorkspacesView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    }
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
            let controller = UIHostingController(rootView: WorkspacesSheet())
            // A form sheet on iPad is too narrow for the list and the detail side by side.
            if UIDevice.current.userInterfaceIdiom == .pad {
                controller.modalPresentationStyle = .fullScreen
            }
            top.present(controller, animated: true)
        #endif
    }
}
