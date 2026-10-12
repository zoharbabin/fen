#if os(macOS)
    import AppKit

    /// The Vim Normal/Insert subset (issue #102). Normal mode takes a key as a command and never types it,
    /// so auto-pair, list continuation and smart Home (issues #15, #16, #51) can't fire from it.
    extension MarkdownNSTextView {
        /// Handles a key press in Normal mode. Returns `false` when AppKit should handle the key as usual.
        func handleVimKey(_ event: NSEvent) -> Bool {
            guard isVimEnabled() else {
                // Turning the preference back on starts in Normal mode, as Vim does.
                vimMode = .normal
                vimIsWaitingForSecondG = false
                return false
            }
            guard vimMode == .normal, !hasMarkedText(), !event.modifierFlags.contains(.command) else { return false }
            var characters = event.characters ?? ""
            // Arrows, Home and the function keys come as private-use characters. They only move the caret,
            // except Forward Delete, which edits text. Normal mode doesn't type or delete.
            if characters.unicodeScalars.contains(where: { (0xF700 ... 0xF8FF).contains($0.value) }) {
                return characters.unicodeScalars.contains(where: { $0.value == 0xF728 })
            }
            // Ctrl keys would reach AppKit's Emacs bindings (Ctrl-K, Ctrl-D, Ctrl-H ...), which edit text.
            if event.modifierFlags.contains(.control) {
                return true
            }
            // A non-Latin layout types no ASCII, so use the physical key.
            if !characters.allSatisfy(\.isASCII) {
                characters = VimCommand.asciiCharacters(
                    forKeyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)
                )
            }
            // Option types special characters, so it never counts as a command.
            let command = VimCommand.command(
                for: event.modifierFlags.contains(.option) ? "" : characters,
                afterG: vimIsWaitingForSecondG
            )
            vimIsWaitingForSecondG = command == .pendingG
            perform(command)
            return true
        }

        /// Leaves Insert mode for Normal mode. Returns `false` when Vim keys are off or it is in Normal mode.
        func leaveVimInsertMode() -> Bool {
            guard isVimEnabled(), vimMode == .insert else { return false }
            let target = VimMotion.locationAfterLeavingInsert(in: string as NSString, from: selectedRange().location)
            setSelectedRange(NSRange(location: target, length: 0))
            vimMode = .normal
            refreshVimCaret()
            return true
        }

        /// The width of the block caret: the character under it, or a space past the end of a line.
        var vimCaretWidth: CGFloat {
            let text = string as NSString
            let caret = selectedRange().location
            let under = caret < text.length && text.character(at: caret) != 10
                ? text.substring(with: text.rangeOfComposedCharacterSequence(at: caret))
                : " "
            let font = font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            return max(ceil(under.size(withAttributes: [.font: font]).width), 1)
        }

        private func perform(_ command: VimCommand) {
            let text = string as NSString
            switch command {
            case .down, .up:
                if command == .down {
                    moveDown(nil)
                } else {
                    moveUp(nil)
                }
                move(to: VimMotion.resting(in: text, at: selectedRange().location))
            case let .insert(place):
                guard isEditable else { return }
                move(to: VimMotion.location(for: .insert(place), in: text, from: selectedRange().location) ?? 0)
                vimMode = .insert
                refreshVimCaret()
            case .pendingG, .ignore:
                break
            default:
                if let target = VimMotion.location(for: command, in: text, from: selectedRange().location) {
                    move(to: target)
                }
            }
        }

        private func move(to location: Int) {
            setSelectedRange(NSRange(location: location, length: 0))
            scrollRangeToVisible(selectedRange())
        }

        private func refreshVimCaret() {
            updateInsertionPointStateAndRestartTimer(true)
            setNeedsDisplay(visibleRect)
        }
    }
#endif
