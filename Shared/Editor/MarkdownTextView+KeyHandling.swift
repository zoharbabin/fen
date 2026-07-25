#if os(macOS)
    import AppKit

    /// Tab/Backspace/Enter/Home key handling (issues #15, #17, #51) Coordinator methods, split
    /// out of `MarkdownTextView.swift` to keep that file under the project's file-length lint
    /// limit -- mirrors `MarkdownTextView+FocusMode.swift`'s precedent.
    extension MarkdownTextView.Coordinator {
        @MainActor func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let preferences = Preferences.shared
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                return dismissSlashMenuIfOpenOnEscape()
            case #selector(NSResponder.insertTab(_:)):
                guard preferences.editorConvertTabs, textView.selectedRange().length == 0 else { return false }
                insertTabAsSpaces(in: textView)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.selectedRange().length == 0 else { return false }
                return handleBackspace(in: textView)
            case #selector(NSResponder.insertNewline(_:)):
                guard preferences.editorInsertPrefixInBlock, textView.selectedRange().length == 0 else {
                    return false
                }
                return handleNewline(in: textView, autoIncrement: preferences.editorAutoIncrementNumberedLists)
            case #selector(NSResponder.moveToLeftEndOfLine(_:)),
                 #selector(NSResponder.moveToBeginningOfLine(_:)),
                 #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                // AppKit's StandardKeyBinding.dict binds the plain Home key to
                // scrollToBeginningOfDocument:, not moveToBeginningOfLine:/moveToLeftEndOfLine:
                // (those need Control+Home) -- so the plain key must be intercepted here too.
                guard preferences.editorSmartHome else { return false }
                return handleSmartHome(in: textView)
            default:
                return false
            }
        }

        @MainActor func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
        ) -> Bool {
            guard Preferences.shared.editorCompleteMatchingCharacters,
                  let replacementString, replacementString.count == 1,
                  let character = replacementString.first else { return true }
            return !applyPairDecision(for: character, in: textView, range: range)
        }

        /// Inserts spaces to the next tab stop at the cursor's column, and reports the
        /// edit through the same `textDidChange` path a real keystroke would take (this
        /// method fires *instead of* the normal keystroke once `doCommandBySelector`
        /// returns true, so `NSTextView` never generates its own change notification here).
        @MainActor private func insertTabAsSpaces(in textView: NSTextView) {
            let location = textView.selectedRange().location
            let column = columnOfCharacter(at: location, in: textView.string)
            let spaces = MarkdownTextEditing.tabInsertion(atColumn: column)
            replaceAndNotify(in: textView, range: NSRange(location: location, length: 0), with: spaces)
        }

        /// Returns `true` if this Backspace was fully handled here (outdent or atomic pair
        /// deletion), `false` to let `NSTextView` perform its normal single-character delete.
        @MainActor private func handleBackspace(in textView: NSTextView) -> Bool {
            let location = textView.selectedRange().location
            let ns = textView.string as NSString

            if Preferences.shared.editorConvertTabs {
                let column = columnOfCharacter(at: location, in: textView.string)
                let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
                let prefix = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
                if column > 0, let outdent = MarkdownTextEditing.outdentAmount(linePrefix: prefix) {
                    replaceAndNotify(
                        in: textView, range: NSRange(location: location - outdent, length: outdent), with: ""
                    )
                    return true
                }
            }

            if Preferences.shared.editorCompleteMatchingCharacters, location > 0, location < ns.length {
                let before = Character(ns.substring(with: NSRange(location: location - 1, length: 1)))
                let after = Character(ns.substring(with: NSRange(location: location, length: 1)))
                if MarkdownTextEditing.isAtomicPairDeletion(before: before, after: after) {
                    replaceAndNotify(
                        in: textView, range: NSRange(location: location - 1, length: 2), with: ""
                    )
                    return true
                }
            }

            return false
        }

        /// Returns `true` if Enter was handled here (list/blockquote continuation or
        /// termination), `false` to let `NSTextView` insert a plain newline.
        @MainActor private func handleNewline(in textView: NSTextView, autoIncrement: Bool) -> Bool {
            let location = textView.selectedRange().location
            let ns = textView.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            // Only continue when the caret is at the true end of the line -- matching
            // MacDown's original behavior of not continuing mid-line.
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

        /// Returns `true` if Home was handled here (moved to first-non-whitespace or column
        /// 0), `false` to let `NSTextView` perform its normal Home behavior (e.g. on a
        /// soft-wrapped visual row, where smart Home doesn't apply).
        @MainActor private func handleSmartHome(in textView: NSTextView) -> Bool {
            let location = textView.selectedRange().location
            let ns = textView.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))

            // Guard against soft-wrapped lines: if the line's start and the caret's current
            // position aren't on the same laid-out visual row, this is a wrapped row, not a
            // true line start -- fall back to normal behavior (matches MacDown's fix for its
            // own issue #103).
            if let layoutManager = textView.layoutManager, ns.length > 0 {
                let lastCharacterIndex = ns.length - 1
                let lineGlyphIndex = layoutManager.glyphIndexForCharacter(at: min(
                    lineRange.location,
                    lastCharacterIndex
                ))
                let caretGlyphIndex = layoutManager.glyphIndexForCharacter(at: min(location, lastCharacterIndex))
                let lineFragmentTop = layoutManager
                    .lineFragmentRect(forGlyphAt: lineGlyphIndex, effectiveRange: nil).origin.y
                let caretFragmentTop = layoutManager.lineFragmentRect(
                    forGlyphAt: caretGlyphIndex,
                    effectiveRange: nil
                ).origin.y
                if lineFragmentTop != caretFragmentTop {
                    return false
                }
            }

            let line = ns.substring(with: lineRange)
            let trimmedLine = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let caretColumn = location - lineRange.location
            let targetColumn = MarkdownTextEditing.smartHomeColumn(
                line: Substring(trimmedLine), caretColumn: caretColumn
            )
            textView.setSelectedRange(NSRange(location: lineRange.location + targetColumn, length: 0))
            return true
        }

        /// Applies `MarkdownTextEditing.pairDecision` for a just-typed character. Returns
        /// `true` if this method fully handled the edit (the caller must then suppress the
        /// original `shouldChangeTextIn` edit), `false` to let it proceed normally.
        @MainActor private func applyPairDecision(
            for character: Character,
            in textView: NSTextView,
            range: NSRange
        ) -> Bool {
            let ns = textView.string as NSString
            let hasSelection = range.length > 0
            let nextCharacter: Character? = (!hasSelection && range.location < ns.length)
                ? Character(ns.substring(with: NSRange(location: range.location, length: 1)))
                : nil

            switch MarkdownTextEditing.pairDecision(
                for: character, nextCharacter: nextCharacter, hasSelection: hasSelection
            ) {
            case let .insertPair(opening, closing):
                replaceAndNotify(in: textView, range: range, with: "\(opening)\(closing)")
                textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return true
            case .skipOver:
                textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return true
            case let .wrapSelection(opening, closing):
                let selected = ns.substring(with: range)
                replaceAndNotify(in: textView, range: range, with: "\(opening)\(selected)\(closing)")
                textView.setSelectedRange(NSRange(location: range.location + 1, length: range.length))
                return true
            case .insertPlain:
                return false
            }
        }

        /// The 0-based column of `location` on its own line (distance from the start of the
        /// line, not the whole document).
        @MainActor private func columnOfCharacter(at location: Int, in text: String) -> Int {
            let ns = text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
            return location - lineStart
        }

        /// Performs a text replacement the same way a real keystroke would: through
        /// `NSTextView.insertText`-equivalent undo-registered replacement, then notifying
        /// `parent`/`onTextChange` exactly like `textDidChange` does, since these
        /// programmatic edits bypass the normal `NSText` notification chain.
        @MainActor private func replaceAndNotify(
            in textView: NSTextView,
            range: NSRange,
            with replacement: String
        ) {
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            parent.text = textView.string
            parent.onTextChange?()
        }
    }
#endif
