#if os(macOS)
    import SwiftUI

    public extension Notification.Name {
        /// Posted by the Find menu. `SplitEditorView` in the key window opens or drives its find bar (issue #255).
        static let findShow = Notification.Name("fenFindShow")
        static let findShowReplace = Notification.Name("fenFindShowReplace")
        static let findNext = Notification.Name("fenFindNext")
        static let findPrevious = Notification.Name("fenFindPrevious")
        static let findUseSelection = Notification.Name("fenFindUseSelection")
    }

    /// Edit > Find. One find bar per document window, for the editor and the preview (issue #255).
    public struct FindCommands: Commands {
        public init() {}

        public var body: some Commands {
            CommandGroup(after: .textEditing) {
                Section {
                    post("Find…", .findShow).keyboardShortcut("f", modifiers: .command)
                    post("Find and Replace…", .findShowReplace).keyboardShortcut("f", modifiers: [.command, .option])
                    post("Find Next", .findNext).keyboardShortcut("g", modifiers: .command)
                    post("Find Previous", .findPrevious).keyboardShortcut("g", modifiers: [.command, .shift])
                    post("Use Selection for Find", .findUseSelection).keyboardShortcut("e", modifiers: .command)
                }
            }
        }

        private func post(_ title: String, _ name: Notification.Name) -> some View {
            Button(title) { NotificationCenter.default.post(name: name, object: nil) }
        }
    }
#endif
