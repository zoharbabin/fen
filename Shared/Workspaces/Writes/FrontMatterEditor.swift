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
        guard !value.contains("\n"), !value.contains("\r") else { throw FrontMatterError.multilineValue }
        return try setRaw(key: key, yaml: scalar(value), in: text)
    }

    /// Sets a key to `yaml`, which must already be one line of valid YAML (`true`, `3`, `[a, b]`).
    static func setRaw(key: String, yaml: String, in text: String) throws -> String {
        guard DocumentSchema.isValidName(key) else { throw FrontMatterError.invalidKey }
        guard !yaml.contains("\n"), !yaml.contains("\r") else { throw FrontMatterError.multilineValue }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let entry = "\(key): \(yaml)"
        guard let block = block(in: text) else {
            return "---" + newline + entry + newline + "---" + newline + text
        }
        var lines = block.lines
        if let index = lines.firstIndex(where: { keyName(of: $0) == key }) {
            guard !hasNestedValue(at: index, in: lines) else { throw FrontMatterError.complexExistingValue }
            lines[index] = entry
        } else {
            lines.append(entry)
        }
        return block.opening + lines.joined(separator: newline) + newline + block.closingAndRest
    }

    /// Renames a key and keeps its value, comments, and every other line. A missing key, or a
    /// new name that is already taken, leaves the text as it was.
    static func renameKey(from old: String, to new: String, in text: String) throws -> String {
        guard DocumentSchema.isValidName(new) else { throw FrontMatterError.invalidKey }
        guard let block = block(in: text),
              let index = block.lines.firstIndex(where: { keyName(of: $0) == old }),
              !block.lines.contains(where: { keyName(of: $0) == new }) else { return text }
        var lines = block.lines
        let colon = lines[index].firstIndex(of: ":") ?? lines[index].endIndex
        lines[index] = new + lines[index][colon...]
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        return block.opening + lines.joined(separator: newline) + newline + block.closingAndRest
    }

    /// Removes a one-line key. Block values (lists, `|`, `>`) are left alone.
    static func removeKey(_ key: String, in text: String) throws -> String {
        guard let block = block(in: text), let index = block.lines.firstIndex(where: { keyName(of: $0) == key }) else {
            return text
        }
        guard !hasNestedValue(at: index, in: block.lines) else { throw FrontMatterError.complexExistingValue }
        var lines = block.lines
        lines.remove(at: index)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let body = lines.isEmpty ? "" : lines.joined(separator: newline) + newline
        return block.opening + body + block.closingAndRest
    }

    /// A list or block scalar under the key: a one-line edit would break it.
    private static func hasNestedValue(at index: Int, in lines: [String]) -> Bool {
        let next = lines.index(after: index)
        if next < lines.endIndex, lines[next].first == " " || lines[next].first == "\t" || lines[next].hasPrefix("- ") {
            return true
        }
        let existing = lines[index].drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
        return existing.hasPrefix("|") || existing.hasPrefix(">")
    }

    /// Everything up to the closing fence: the opening line and every key line.
    static func head(of text: String) -> String? {
        block(in: text).map { String(text.dropLast($0.closingAndRest.count)) }
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
    static func scalar(_ value: String) -> String {
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
