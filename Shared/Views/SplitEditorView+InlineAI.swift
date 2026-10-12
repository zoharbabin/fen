import SwiftUI

extension SplitEditorView {
    /// The toolbar button for "Ask AI" and "Enrich" (issue #6). Off in Preview mode, where no
    /// editor can take the edit.
    var inlineAIButton: some View {
        InlineAIButton(controller: inlineAI, document: document, caret: editorCaret)
            .disabled(!isEditorShown)
    }

    /// Lets the controller read the text and hand the editor an edit. The edit goes through the
    /// editor's undo stack, like the related-document links (issue #8).
    func bindInlineAI() {
        inlineAI.bind(currentText: { [document] in document.text }, insert: { [related] in related.apply($0) })
    }
}
