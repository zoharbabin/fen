import FenCore
import SwiftUI

@main
struct FenApp: App {
    @Environment(\.openWindow) private var openWindow

    init() {
        MCPController.shared.launch()
        ScheduledEnrichment.launch()
        #if DEBUG
            DeviceSelfTest.runIfRequested()
        #endif
    }

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument.makeNew() }, editor: { file in
            SplitEditorView(document: file.document)
                .frame(minWidth: 600, minHeight: 400)
                .onAppear { file.document.fileURL = file.fileURL }
                .onChange(of: file.fileURL) { _, newValue in file.document.fileURL = newValue }
        })
        .defaultSize(width: 1000, height: 700)
        .commands {
            macOSCommands()
        }

        #if os(macOS)
            Settings {
                SettingsView()
            }

            Window("Workspaces", id: "workspaces") {
                WorkspacesView()
            }
            .defaultSize(width: 860, height: 560)

            Window("About Fen", id: "about") {
                AboutView()
            }
            .windowResizability(.contentSize)
        #endif
    }

    @CommandsBuilder
    func macOSCommands() -> some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Fen") {
                openWindow(id: "about")
            }
            // The App Store updates the app, and it rejects an app that replaces itself (issue #40).
            #if !APPSTORE
                Button("Check for Updates…") {
                    Task { await AppUpdater.checkForUpdates() }
                }
            #endif
        }

        CommandGroup(replacing: .help) {
            Link("Fen Help", destination: URL(string: "https://github.com/zoharbabin/fen#readme")!)
        }

        FindCommands()
        FormattingCommands()
        copyCommands()
        fileMenuCommands()

        ViewCommands()
    }

    /// Grouped because `CommandsBuilder` accepts at most ten children.
    @CommandsBuilder
    func fileMenuCommands() -> some Commands {
        CommandGroup(after: .newItem) {
            Button("Workspaces…") {
                openWindow(id: "workspaces")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Ask Your Workspaces…") {
                AskPanelRequest.shared.isRequested = true
                openWindow(id: "workspaces")
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
        }
        // The system's Browse All Versions (issue #59). It is also under Revert To, which is easy to miss.
        CommandGroup(after: .saveItem) {
            Button("Browse Version History…") {
                NSApp.sendAction(#selector(NSDocument.browseVersions(_:)), to: nil, from: nil)
            }
        }
        exportHTMLCommands()
        exportPDFCommands()
        printCommands()
    }
}
