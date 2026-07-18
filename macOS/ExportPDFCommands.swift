import FenCore
import SwiftUI

/// "Export to PDF…" menu command (issue #30) -- posts `.exportToPDF` for the focused
/// `SplitEditorView` to handle, mirroring `exportHTMLCommands()`.
extension FenApp {
    @CommandsBuilder
    func exportPDFCommands() -> some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export to PDF…") {
                NotificationCenter.default.post(name: .exportToPDF, object: nil)
            }
        }
    }
}
