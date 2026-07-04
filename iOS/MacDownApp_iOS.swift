import MacDownCore
import SwiftUI

@main
struct MacDownApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }, editor: { file in
            SplitEditorView(document: file.document)
                .toolbarRole(.editor)
        })
    }
}
