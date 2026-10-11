#if os(macOS)
    import Foundation

    /// Whether the editor takes letter keys as commands (Normal) or as text (Insert). Issue #102.
    enum VimMode {
        case normal
        case insert
    }

    /// What one Normal-mode key does. This is the whole Vim subset: no counts, operators, Visual mode,
    /// registers or `:` commands.
    enum VimCommand: Equatable {
        case left, right, down, up
        case wordForward, wordBack
        case lineStart, lineEnd
        case documentStart, documentEnd
        /// `i`, `a`, `I` and `A`: go to Insert mode, after moving the caret.
        case insert(VimInsertPlace)
        /// `g`, waiting for a second `g`.
        case pendingG
        /// A key with no command. It is swallowed, so it never types a letter.
        case ignore

        /// The command for the characters of one key press. `afterG` is true when the key before was `g`.
        static func command(for characters: String, afterG: Bool) -> VimCommand {
            if afterG {
                return characters == "g" ? .documentStart : .ignore
            }
            return keys[characters] ?? .ignore
        }

        private static let keys: [String: VimCommand] = [
            "h": .left, "\u{7F}": .left, "l": .right,
            "j": .down, "\r": .down, "\n": .down, "k": .up,
            "w": .wordForward, "b": .wordBack,
            "0": .lineStart, "$": .lineEnd, "G": .documentEnd, "g": .pendingG,
            "i": .insert(.here), "a": .insert(.afterCaret), "I": .insert(.lineStart), "A": .insert(.lineEnd),
        ]
    }

    enum VimInsertPlace: Equatable {
        case here, afterCaret, lineStart, lineEnd
    }

    /// Caret math on plain text. Locations are UTF-16 offsets, as in `NSString`.
    enum VimMotion {
        /// Where the caret goes. `nil` for `down`, `up` and `ignore`, which follow the wrapped lines on
        /// screen and so need the layout. The caret stays on a real character, as in Vim: it doesn't wrap
        /// to another line, and it doesn't rest after the last character.
        static func location(for command: VimCommand, in text: NSString, from caret: Int) -> Int? {
            let caret = min(max(caret, 0), text.length)
            let line = text.lineRange(for: NSRange(location: caret, length: 0))
            let end = contentEnd(of: line, in: text)
            switch command {
            case .left: return max(line.location, caret - 1)
            case .right: return restingPlace(min(caret + 1, end), line: line, end: end)
            case .lineStart: return line.location
            case .lineEnd: return restingPlace(end, line: line, end: end)
            case .documentStart: return 0
            case .documentEnd: return lastLineStart(in: text)
            case .wordForward: return restingPlace(nextWordStart(in: text, from: caret), in: text)
            case .wordBack: return previousWordStart(in: text, from: caret)
            case let .insert(place): return insertLocation(place, caret: caret, line: line, end: end)
            case .down, .up, .pendingG, .ignore: return nil
            }
        }

        /// Where the caret lands on leaving Insert mode: one character back, unless it is at a line start.
        static func locationAfterLeavingInsert(in text: NSString, from caret: Int) -> Int {
            let caret = min(max(caret, 0), text.length)
            let line = text.lineRange(for: NSRange(location: caret, length: 0))
            return max(line.location, caret - 1)
        }

        /// Moves a caret that sits after the last character of a line back onto it. Use after `down` and `up`.
        static func resting(in text: NSString, at caret: Int) -> Int {
            let caret = min(max(caret, 0), text.length)
            let line = text.lineRange(for: NSRange(location: caret, length: 0))
            return restingPlace(caret, line: line, end: contentEnd(of: line, in: text))
        }

        // MARK: - Words

        private enum CharacterClass {
            case space, word, punctuation
        }

        private static func characterClass(_ unit: unichar) -> CharacterClass {
            guard let scalar = Unicode.Scalar(unit) else { return .word }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return .space
            }
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                return .word
            }
            return .punctuation
        }

        /// The start of the next word, as Vim's `w`: skip the rest of this word, then the spaces.
        static func nextWordStart(in text: NSString, from caret: Int) -> Int {
            var index = caret
            guard index < text.length else { return text.length }
            let start = characterClass(text.character(at: index))
            while index < text.length, start != .space, characterClass(text.character(at: index)) == start {
                index += 1
            }
            while index < text.length, characterClass(text.character(at: index)) == .space {
                index += 1
            }
            return index
        }

        /// The start of this word, or of the one before it when the caret is already at a start (Vim's `b`).
        static func previousWordStart(in text: NSString, from caret: Int) -> Int {
            var index = min(caret, text.length)
            while index > 0, characterClass(text.character(at: index - 1)) == .space {
                index -= 1
            }
            guard index > 0 else { return 0 }
            let kind = characterClass(text.character(at: index - 1))
            while index > 0, characterClass(text.character(at: index - 1)) == kind {
                index -= 1
            }
            return index
        }

        // MARK: - Lines

        /// The end of a line's text, before its line break.
        private static func contentEnd(of line: NSRange, in text: NSString) -> Int {
            var end = NSMaxRange(line)
            while end > line.location, [10, 13].contains(text.character(at: end - 1)) {
                end -= 1
            }
            return end
        }

        private static func restingPlace(_ location: Int, line: NSRange, end: Int) -> Int {
            location >= end && end > line.location ? end - 1 : location
        }

        private static func restingPlace(_ location: Int, in text: NSString) -> Int {
            resting(in: text, at: location)
        }

        /// The last line's start. A final line break ends that line, so it doesn't start another.
        private static func lastLineStart(in text: NSString) -> Int {
            guard text.length > 0 else { return 0 }
            return text.lineRange(for: NSRange(location: text.length - 1, length: 0)).location
        }

        private static func insertLocation(_ place: VimInsertPlace, caret: Int, line: NSRange, end: Int) -> Int {
            switch place {
            case .here: caret
            case .afterCaret: min(caret + 1, end)
            case .lineStart: line.location
            case .lineEnd: end
            }
        }
    }
#endif
