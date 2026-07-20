import FenCore
import SwiftUI

/// "Print…" menu command (issue #32) -- posts `.printDocument` for the focused `SplitEditorView`
/// to handle, mirroring `exportPDFCommands()`. Replaces (rather than duplicates) the disabled
/// default File > Print item SwiftUI's `.printItem` command group already contributes.
extension FenApp {
    @CommandsBuilder
    func printCommands() -> some Commands {
        CommandGroup(after: .printItem) {
            Button("Print…") {
                NotificationCenter.default.post(name: .printDocument, object: nil)
            }
            .keyboardShortcut("p", modifiers: .command)
        }
    }
}
