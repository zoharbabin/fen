import FenCore
import SwiftUI

@main
struct FenApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }, editor: { file in
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
        }

        CommandGroup(replacing: .help) {
            Link("Fen Help", destination: URL(string: "https://github.com/zoharbabin/fen#readme")!)
        }

        findCommands()
        formattingCommands()

        CommandGroup(after: .sidebar) {
            Section {
                Button("Toggle Preview") {
                    NotificationCenter.default.post(name: .togglePreview, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Toggle Editor") {
                    NotificationCenter.default.post(name: .toggleEditor, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Toggle Outline") {
                    NotificationCenter.default.post(name: DocumentOutline.toggleOutlineNotification, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        CommandGroup(after: .toolbar) {
            Section {
                Button("Zoom In") {
                    Preferences.shared.increaseFontSize()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    Preferences.shared.decreaseFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    Preferences.shared.resetFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    @CommandsBuilder
    func formattingCommands() -> some Commands {
        CommandGroup(after: .textFormatting) {
            Section {
                Button("Bold") {
                    NotificationCenter.default.post(name: .insertMarkdownFormatting, object: "bold")
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    NotificationCenter.default.post(name: .insertMarkdownFormatting, object: "italic")
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Code") {
                    NotificationCenter.default.post(name: .insertMarkdownFormatting, object: "code")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            Section {
                Button("Heading 1") {
                    NotificationCenter.default.post(name: .insertMarkdownFormatting, object: "h1")
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Heading 2") {
                    NotificationCenter.default.post(name: .insertMarkdownFormatting, object: "h2")
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Heading 3") {
                    NotificationCenter.default.post(name: .insertMarkdownFormatting, object: "h3")
                }
                .keyboardShortcut("3", modifiers: .command)
            }
        }
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

// MARK: - Notification Names

extension Notification.Name {
    static let insertMarkdownFormatting = Notification.Name("insertMarkdownFormatting")
    static let togglePreview = Notification.Name("togglePreview")
    static let toggleEditor = Notification.Name("toggleEditor")
}
