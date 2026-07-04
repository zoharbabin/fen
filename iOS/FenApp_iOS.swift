import FenCore
import SwiftUI

@main
struct FenApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }, editor: { file in
            SplitEditorView(document: file.document)
                .toolbarRole(.editor)
        })
    }
}
