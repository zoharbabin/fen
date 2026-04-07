import SwiftUI

@main
struct MacDownApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { file in
            SplitEditorView(document: file.document)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            macOSCommands()
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }

    @CommandsBuilder
    func macOSCommands() -> some Commands {
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
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let insertMarkdownFormatting = Notification.Name("insertMarkdownFormatting")
    static let togglePreview = Notification.Name("togglePreview")
    static let toggleEditor = Notification.Name("toggleEditor")
}
