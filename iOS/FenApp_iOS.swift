import FenCore
import SwiftUI

@main
struct FenApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }, editor: { file in
            SplitEditorView(document: file.document)
                .toolbarRole(.editor)
                .onAppear { file.document.fileURL = file.fileURL }
                .onChange(of: file.fileURL) { _, newValue in file.document.fileURL = newValue }
        })
    }
}
