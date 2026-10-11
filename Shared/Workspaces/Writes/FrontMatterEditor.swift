import Foundation

public enum FrontMatterError: Error, Equatable {
    /// The value has a line break.
    case multilineValue
    /// The key isn't a plain name.
    case invalidKey
    /// The existing value is a list or a block, so a one-line edit would break it.
    case complexExistingValue
}

/// Sets one single-line front matter key and leaves every other byte alone (issue #140): no
/// re-serialising, no reordered keys, no changed quotes or comments.
enum FrontMatterEditor {
    static func hasKey(_ key: String, in text: String) -> Bool {
        guard let block = block(in: text) else { return false }
        return block.lines.contains { keyName(of: $0) == key }
    }

    static func set(key: String, value: String, in text: String) throws -> String {
        guard key.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
            throw FrontMatterError.invalidKey
        }
        guard !value.contains("\n"), !value.contains("\r") else { throw FrontMatterError.multilineValue }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let entry = "\(key): \(scalar(value))"
        guard let block = block(in: text) else {
            return "---" + newline + entry + newline + "---" + newline + text
        }
        var lines = block.lines
        if let index = lines.firstIndex(where: { keyName(of: $0) == key }) {
            let next = lines.index(after: index)
            if next < lines.endIndex, lines[next].first == " " || lines[next].first == "\t"
                || lines[next].hasPrefix("- ") {
                throw FrontMatterError.complexExistingValue
            }
            let existing = lines[index].drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            if existing.hasPrefix("|") || existing.hasPrefix(">") {
                throw FrontMatterError.complexExistingValue
            }
            lines[index] = entry
        } else {
            lines.append(entry)
        }
        return block.opening + lines.joined(separator: newline) + newline + block.closingAndRest
    }

    // MARK: - Parsing

    private struct Block {
        var opening: String
        var lines: [String]
        /// The closing fence and everything after it, byte for byte.
        var closingAndRest: String
    }

    /// Splits `---` front matter from the rest. Lines are kept without their line endings.
    private static func block(in text: String) -> Block? {
        // "\r\n" is one Character in Swift, so lines are split on "\n" and "\r\n" Characters.
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let opening = text.hasPrefix("---\r\n") ? "---\r\n" : "---\n"
        let body = text.dropFirst(4)
        var lines: [String] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            let lineEnd = body[cursor...].firstIndex { $0 == "\n" || $0 == "\r\n" } ?? body.endIndex
            let line = body[cursor ..< lineEnd]
            if line == "---" || line == "..." {
                return Block(opening: opening, lines: lines, closingAndRest: String(body[cursor...]))
            }
            lines.append(String(line))
            cursor = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        return nil
    }

    private static func keyName(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("#") else { return nil }
        return String(line[..<colon]).trimmingCharacters(in: .whitespaces)
    }

    /// Plain when that is safe, otherwise double-quoted.
    private static func scalar(_ value: String) -> String {
        let plain = value.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._/-]*$", options: .regularExpression) != nil
            && !value.hasSuffix(" ")
            && !["true", "false", "null", "yes", "no", "on", "off", "~"].contains(value.lowercased())
            && Double(value) == nil
        if plain {
            return value
        }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
