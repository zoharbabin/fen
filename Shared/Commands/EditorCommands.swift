import SwiftUI

// The menu commands macOS and iPadOS share (issue #42). iPadOS shows them in the menu bar and in
// the shortcut list you get by holding Cmd on a hardware keyboard, so one definition keeps the two
// platforms' shortcuts the same.

/// Format > Bold, Italic, headings, lists, links and the rest.
public struct FormattingCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandGroup(after: .textFormatting) {
            Section {
                button(.bold).keyboardShortcut("b", modifiers: .command)
                button(.italic).keyboardShortcut("i", modifiers: .command)
                button(.strikethrough).keyboardShortcut("x", modifiers: [.command, .shift])
                button(.inlineCode).keyboardShortcut("k", modifiers: [.command, .shift])
                button(.codeBlock).keyboardShortcut("k", modifiers: [.command, .option])
            }

            Section {
                button(.heading1).keyboardShortcut("1", modifiers: .command)
                button(.heading2).keyboardShortcut("2", modifiers: .command)
                button(.heading3).keyboardShortcut("3", modifiers: .command)
            }

            Section {
                button(.bulletList).keyboardShortcut("u", modifiers: [.command, .shift])
                button(.numberedList).keyboardShortcut("n", modifiers: [.command, .shift])
                button(.taskItem).keyboardShortcut("j", modifiers: [.command, .shift])
                button(.blockquote).keyboardShortcut("q", modifiers: [.command, .shift])
            }

            Section {
                button(.link).keyboardShortcut("k", modifiers: .command)
                button(.image).keyboardShortcut("i", modifiers: [.command, .shift])
                button(.horizontalRule).keyboardShortcut("h", modifiers: [.command, .shift])
                button(.table).keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }

    private func button(_ action: FormattingAction) -> some View {
        Button(action.title) {
            NotificationCenter.default.post(name: .insertMarkdownFormatting, object: action.identifier)
        }
    }
}

/// View > panes, outline, focus mode, live preview and zoom. Each command posts a notification
/// that `SplitEditorView` handles, because the view's state is private to it.
public struct ViewCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            Section {
                post("Toggle Preview", .togglePreview).keyboardShortcut("r", modifiers: [.command, .shift])
                post("Toggle Editor", .toggleEditor).keyboardShortcut("e", modifiers: [.command, .shift])
                post("Toggle Outline", DocumentOutline.toggleOutlineNotification)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                post("Toggle Focus Mode", FocusModeEditing.toggleFocusModeNotification)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                post("Toggle Live Preview", LivePreviewEditing.toggleLivePreviewNotification)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        CommandGroup(after: .toolbar) {
            Section {
                Button("Zoom In") { Preferences.shared.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { Preferences.shared.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { Preferences.shared.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    private func post(_ title: String, _ name: Notification.Name) -> some View {
        Button(title) { NotificationCenter.default.post(name: name, object: nil) }
    }
}
