import FenCore
import SwiftUI

/// "Copy as Raw HTML" / "Copy as Rich Text Formatted" menu commands (issue #33) -- posts a
/// notification for the focused `SplitEditorView` to handle, mirroring
/// `exportHTMLCommands()`/`printCommands()`. Placed in the Edit menu's Cut/Copy/Paste group
/// (`.pasteboard`), not File's export section -- these are copy actions, not file exports.
extension FenApp {
    @CommandsBuilder
    func copyCommands() -> some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Copy as Raw HTML") {
                NotificationCenter.default.post(name: .copyAsRawHTML, object: nil)
            }
            Button("Copy as Rich Text Formatted") {
                NotificationCenter.default.post(name: .copyAsRichTextFormatted, object: nil)
            }
        }
    }
}
