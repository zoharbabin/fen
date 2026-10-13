import Foundation

/// Turns text from outside Fen, such as the clipboard after a Safari selection or a Notes copy, into
/// the text of a new document (issue #43). Pure, so the rules are testable without a pasteboard.
/// The share extension compiles this file by itself, so it must not use other Fen types.
public enum SharedTextImport {
    /// The largest import, in UTF-8 bytes. Text over this is almost certainly a mistaken copy, and
    /// it would make the editor slow to open.
    public static let maxBytes = 2_000_000

    public enum Failure: Error, Equatable, LocalizedError {
        case tooLarge

        public var errorDescription: String? {
            "The clipboard text is too large to import."
        }
    }

    /// The text of the new document for `raw`, or `nil` when there is nothing worth importing.
    ///
    /// - Line endings become `\n`, and byte order marks are dropped.
    /// - Control characters other than tab and newline are removed. A NUL byte, for one, makes
    ///   other tools treat the file as binary.
    /// - Leading blank lines and trailing whitespace are trimmed. Indentation on the first
    ///   content line stays, since it can be code. The result ends with one newline.
    /// - No front matter and no heading are added. The text is yours as copied.
    /// - Throws `Failure.tooLarge` when the cleaned text is over `maxBytes`. Nothing is cut off.
    public static func text(from raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // Cleaning only removes or shortens, so this bound never rejects text that would fit.
        // It skips the work for a very large paste.
        guard raw.utf8.count <= maxBytes * 4 else { throw Failure.tooLarge }
        let cleaned = trimmed(clean(raw))
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.utf8.count < maxBytes else { throw Failure.tooLarge }
        return cleaned + "\n"
    }

    private static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in raw.unicodeScalars {
            defer { previousWasCarriageReturn = scalar == "\r" }
            switch scalar {
            case "\n":
                if !previousWasCarriageReturn {
                    scalars.append("\n")
                }
            case "\r", "\u{2028}", "\u{2029}":
                scalars.append("\n")
            case "\t":
                scalars.append(scalar)
            case "\u{FEFF}":
                continue
            default:
                if scalar.properties.generalCategory != .control {
                    scalars.append(scalar)
                }
            }
        }
        return String(scalars)
    }

    private static func trimmed(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) {
            lines.removeFirst()
        }
        var result = lines.joined(separator: "\n")
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }
}
