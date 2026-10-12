#if os(macOS)
    import AppKit

    extension MarkdownTextView.Coordinator {
        func noteEdit() {
            related.noteEdit()
        }

        /// Tells the document view what you selected, or the paragraph you are writing, so it can
        /// look up related documents (issue #8).
        @MainActor func reportSelection(in textView: MarkdownNSTextView) {
            parent.caret?.range = textView.selectedRange()
            guard let report = parent.onSelectionChange else { return }
            report(EditorSelection.make(
                in: textView.string,
                selected: textView.selectedRange(),
                typing: related.isWriting
            ))
        }

        /// Applies `insertion` once. It goes through the text view, so Undo takes it back.
        @MainActor func apply(_ insertion: EditorInsertion?, to textView: MarkdownNSTextView) {
            guard let insertion, insertion.id != related.appliedInsertion else { return }
            related.appliedInsertion = insertion.id
            guard insertion.applies(to: textView.string) else { return }
            textView.window?.makeFirstResponder(textView)
            textView.insertText(insertion.text, replacementRange: insertion.range)
        }
    }
#endif
