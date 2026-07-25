#if !os(macOS)
    import UIKit

    /// Tab/Backspace/Enter key handling (issues #15, #17) Coordinator methods, split out of
    /// `MarkdownTextView_iOS.swift` to keep that file under the project's file-length lint
    /// limit -- mirrors `MarkdownTextView+KeyHandling.swift`'s macOS implementation.
    extension MarkdownTextView.Coordinator {
        /// UIKit funnels every insertion, deletion, and replacement through this one
        /// delegate method (there's no `doCommandBySelector` equivalent on iOS), so Tab,
        /// Backspace, Enter, and auto-pair are all recognized here by `range`/`text` shape:
        /// Backspace is an empty replacement over a non-empty range; Tab/Enter/a single
        /// pairable character are single-character insertions.
        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
        ) -> Bool {
            let preferences = Preferences.shared

            if text.isEmpty, range.length == 1 {
                return !handleBackspace(in: textView, range: range, preferences: preferences)
            }
            if text == "\t" {
                guard preferences.editorConvertTabs, range.length == 0 else { return true }
                insertTabAsSpaces(in: textView, at: range.location)
                return false
            }
            if text == "\n" {
                guard preferences.editorInsertPrefixInBlock, range.length == 0 else { return true }
                return !handleNewline(
                    in: textView, at: range.location, autoIncrement: preferences.editorAutoIncrementNumberedLists
                )
            }
            if preferences.editorCompleteMatchingCharacters, text.count == 1, let character = text.first {
                return !applyPairDecision(for: character, in: textView, range: range)
            }
            return true
        }

        private func insertTabAsSpaces(in textView: UITextView, at location: Int) {
            let column = columnOfCharacter(at: location, in: textView.text)
            let spaces = MarkdownTextEditing.tabInsertion(atColumn: column)
            replaceAndNotify(in: textView, range: NSRange(location: location, length: 0), with: spaces)
        }

        private func handleBackspace(in textView: UITextView, range: NSRange, preferences: Preferences) -> Bool {
            let location = range.location + range.length
            let ns = textView.text as NSString

            if preferences.editorConvertTabs {
                let column = columnOfCharacter(at: location, in: textView.text)
                let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
                let prefix = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
                if column > 0, let outdent = MarkdownTextEditing.outdentAmount(linePrefix: prefix) {
                    replaceAndNotify(
                        in: textView, range: NSRange(location: location - outdent, length: outdent), with: ""
                    )
                    return true
                }
            }

            if preferences.editorCompleteMatchingCharacters, location > 0, location < ns.length {
                let before = Character(ns.substring(with: NSRange(location: location - 1, length: 1)))
                let after = Character(ns.substring(with: NSRange(location: location, length: 1)))
                if MarkdownTextEditing.isAtomicPairDeletion(before: before, after: after) {
                    replaceAndNotify(in: textView, range: NSRange(location: location - 1, length: 2), with: "")
                    return true
                }
            }

            return false
        }

        private func handleNewline(in textView: UITextView, at location: Int, autoIncrement: Bool) -> Bool {
            let ns = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = lineRange.location + lineRange.length
            if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 10 {
                contentEnd -= 1
            }
            if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 13 {
                contentEnd -= 1
            }
            guard location == contentEnd else { return false }

            let line = ns.substring(with: NSRange(
                location: lineRange.location,
                length: contentEnd - lineRange.location
            ))
            switch MarkdownTextEditing.continuationAction(forLine: line, autoIncrement: autoIncrement) {
            case let .continuePrefix(prefix):
                replaceAndNotify(in: textView, range: NSRange(location: location, length: 0), with: "\n" + prefix)
                return true
            case .terminateList:
                replaceAndNotify(
                    in: textView,
                    range: NSRange(location: lineRange.location, length: location - lineRange.location),
                    with: ""
                )
                return true
            case .none:
                return false
            }
        }

        private func applyPairDecision(for character: Character, in textView: UITextView, range: NSRange) -> Bool {
            let ns = textView.text as NSString
            let hasSelection = range.length > 0
            let nextCharacter: Character? = (!hasSelection && range.location < ns.length)
                ? Character(ns.substring(with: NSRange(location: range.location, length: 1)))
                : nil

            switch MarkdownTextEditing.pairDecision(
                for: character, nextCharacter: nextCharacter, hasSelection: hasSelection
            ) {
            case let .insertPair(opening, closing):
                replaceAndNotify(in: textView, range: range, with: "\(opening)\(closing)")
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                return true
            case .skipOver:
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                return true
            case let .wrapSelection(opening, closing):
                let selected = ns.substring(with: range)
                replaceAndNotify(in: textView, range: range, with: "\(opening)\(selected)\(closing)")
                textView.selectedRange = NSRange(location: range.location + 1, length: range.length)
                return true
            case .insertPlain:
                return false
            }
        }

        private func columnOfCharacter(at location: Int, in text: String) -> Int {
            let ns = text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
            return location - lineStart
        }

        /// Performs a text replacement and notifies `parent`/`onTextChange` the same way
        /// `textViewDidChange` does, since this bypasses the normal delegate change callback.
        /// Assigning `UITextView.text` (unlike a real keystroke) resets `selectedRange` to the
        /// end of the document, so this restores the caret to where the replacement leaves it.
        private func replaceAndNotify(in textView: UITextView, range: NSRange, with replacement: String) {
            let ns = textView.text as NSString
            textView.text = ns.replacingCharacters(in: range, with: replacement)
            textView.selectedRange = MarkdownTextEditing.selectionAfterReplacement(
                range: range, replacementLength: (replacement as NSString).length
            )
            parent.text = textView.text
            parent.onTextChange?()
        }
    }
#endif
