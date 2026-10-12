import FenCore
import SwiftUI

@main
struct FenApp: App {
    @Environment(\.openWindow) private var openWindow

    init() {
        MCPController.shared.launch()
        ScheduledEnrichment.launch()
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
            Button("Check for Updates…") {
                Task { await AppUpdater.checkForUpdates() }
            }
        }

        CommandGroup(replacing: .help) {
            Link("Fen Help", destination: URL(string: "https://github.com/zoharbabin/fen#readme")!)
        }

        findCommands()
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

    @CommandsBuilder
    func findCommands() -> some Commands {
        CommandGroup(after: .textEditing) {
            Section {
                Button("Find…") {
                    performTextFinderAction(.showFindInterface)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    performTextFinderAction(.nextMatch)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    performTextFinderAction(.previousMatch)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("Find and Replace…") {
                    performTextFinderAction(.showReplaceInterface)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }
    }
}

// MARK: - Find Menu

/// `performTextFinderAction:` reads the requested action from `sender.tag`,
/// so each Find menu item needs a throwaway sender carrying the right tag.
@MainActor
private func performTextFinderAction(_ action: NSTextFinder.Action) {
    let item = NSMenuItem()
    item.tag = action.rawValue
    NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
}
