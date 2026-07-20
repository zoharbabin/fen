import FenCore
import SwiftUI

/// "Copy as HTML" / "Copy as Rich Text" menu commands (issue #33) -- posts a notification for
/// the focused `SplitEditorView` to handle, mirroring `exportHTMLCommands()`/`printCommands()`.
/// Placed in the Edit menu's Cut/Copy/Paste group (`.pasteboard`), not File's export section --
/// these are copy actions, not file exports.
extension FenApp {
    @CommandsBuilder
    func copyCommands() -> some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Copy as HTML") {
                NotificationCenter.default.post(name: .copyAsHTML, object: nil)
            }
            Button("Copy as Rich Text") {
                NotificationCenter.default.post(name: .copyAsRichText, object: nil)
            }
        }
    }
}
