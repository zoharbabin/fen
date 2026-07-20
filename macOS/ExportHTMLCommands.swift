import FenCore
import SwiftUI

/// "Export to HTML…" menu command (issue #31) -- posts `.exportToHTML` for the focused
/// `SplitEditorView` to handle, the same `NotificationCenter` pattern `DocumentOutline`'s
/// outline-toggle command already uses, since the save panel and actual export logic live in
/// `FenCore` where `SplitEditorView` (the observer) is defined.
extension FenApp {
    @CommandsBuilder
    func exportHTMLCommands() -> some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export to HTML…") {
                NotificationCenter.default.post(name: .exportToHTML, object: nil)
            }
        }
    }
}
