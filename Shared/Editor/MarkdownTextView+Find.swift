#if os(macOS)
    import AppKit

    /// The editor side of Find (issue #255). `FindState` drives it; nothing here moves the caret or the
    /// selection except the calls that say so, because in Live Preview a caret on a match would turn its
    /// rendered line back into source.
    extension MarkdownTextView.Coordinator: FindEditorTarget {
        var findText: String {
            textView?.string ?? ""
        }

        var findSelection: NSRange {
            textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        }

        var isFindFocused: Bool {
            guard let textView else { return false }
            return textView.window?.firstResponder === textView
        }

        func showFindMatches(_ ranges: [NSRange], current: Int?, scroll: Bool) {
            guard let textView else { return }
            findPainter.show(ranges, current: current, in: textView, scroll: scroll)
            if scroll {
                findPainter.pulse(in: textView)
            }
        }

        func clearFindMatches() {
            guard let textView else { return }
            findPainter.clear(in: textView)
        }

        func replaceFindMatches(_ ranges: [NSRange], with strings: [String]) {
            guard let textView, !ranges.isEmpty, ranges.count == strings.count else { return }
            let values = ranges.map { NSValue(range: $0) }
            guard textView.shouldChangeText(inRanges: values, replacementStrings: strings) else { return }
            // Same shape as `replaceAndNotify`: replacing characters re-posts the selection mid-edit, and Focus
            // Mode must not react to that until the storage has finished editing.
            isPerformingProgrammaticTextEdit = true
            textView.textStorage?.beginEditing()
            for (range, string) in zip(ranges, strings).reversed() {
                textView.textStorage?.replaceCharacters(in: range, with: string)
            }
            textView.textStorage?.endEditing()
            if ranges.count == 1, let string = strings.first {
                textView.setSelectedRange(NSRange(
                    location: ranges[0].location + (string as NSString).length,
                    length: 0
                ))
            }
            textView.didChangeText()
            textView.undoManager?.setActionName(ranges.count == 1 ? "Replace" : "Replace All")
            isPerformingProgrammaticTextEdit = false
            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        func selectFindRange(_ range: NSRange) {
            guard let textView, NSMaxRange(range) <= (textView.string as NSString).length else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }

        func selectFindRanges(_ ranges: [NSRange]) {
            guard let textView, !ranges.isEmpty else { return }
            textView.window?.makeFirstResponder(textView)
            textView.selectedRanges = ranges.map { NSValue(range: $0) }
            textView.scrollRangeToVisible(ranges[0])
        }

        func focusFindTarget() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    extension MarkdownTextView {
        /// Registers this editor as the window's Find target.
        func finding(_ state: FindState) -> Self {
            var copy = self
            copy.find = state
            return copy
        }
    }
#endif
