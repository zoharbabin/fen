#if !os(macOS)
    import UIKit

    extension MarkdownTextView.Coordinator {
        func noteEdit() {
            related.noteEdit()
        }

        /// Tells the document view what you selected, or the paragraph you are writing, so it can
        /// look up related documents (issue #8).
        @MainActor func reportSelection(in textView: UITextView) {
            parent.caret?.range = textView.selectedRange
            guard let report = parent.onSelectionChange else { return }
            report(EditorSelection.make(in: textView.text, selected: textView.selectedRange, typing: related.isWriting))
        }

        /// Applies `insertion` once. It goes through the text view, so Undo takes it back.
        @MainActor func apply(_ insertion: EditorInsertion?, to textView: UITextView) {
            guard let insertion, insertion.id != related.appliedInsertion else { return }
            related.appliedInsertion = insertion.id
            guard insertion.applies(to: textView.text),
                  let start = textView.position(from: textView.beginningOfDocument, offset: insertion.range.location),
                  let end = textView.position(from: start, offset: insertion.range.length),
                  let range = textView.textRange(from: start, to: end) else { return }
            textView.replace(range, withText: insertion.text)
            textViewDidChange(textView)
        }
    }
#endif
