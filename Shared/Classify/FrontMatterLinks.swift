import Foundation

/// Finds the names in the front matter fields of a document and rewrites them as `[[wiki links]]`
/// (issue #11). It works on the front matter lines only and keeps every other line as it was.
/// It reads three shapes: `key: value`, `key: [a, b]`, and a block list under `key:`.
enum FrontMatterLinks {
    struct Mention: Equatable {
        let field: String
        let value: String
    }

    /// The most characters of a value that can be a name.
    static let maxMentionLength = 60

    static func mentions(in lines: [String], fields: Set<String>) -> [Mention] {
        walk(lines, fields: fields) { _, _ in nil }.mentions
    }

    /// The lines with every mention that `link` names a target for replaced by `"[[target]]"`.
    static func rewrite(_ lines: [String], fields: Set<String>, link: (Mention) -> String?) -> [String] {
        walk(lines, fields: fields) { field, value in link(Mention(field: field, value: value)) }.lines
    }

    /// A value that can be the name of something. A date, a number, a URL and a sentence are not.
    static func isMention(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.count <= maxMentionLength, !text.contains("[["),
              text.rangeOfCharacter(from: .letters) != nil, !text.contains("://"),
              text.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil,
              text.range(of: #"[.,;:!?]"#, options: .regularExpression) == nil,
              text.split(separator: " ").count <= 5 else { return false }
        return true
    }

    // MARK: - Walking the lines

    private static func walk(
        _ lines: [String],
        fields: Set<String>,
        visit: (String, String) -> String?
    ) -> (lines: [String], mentions: [Mention]) {
        var output = lines
        var found: [Mention] = []
        var blockField: String?
        for index in lines.indices {
            let line = lines[index]
            if let item = blockItem(line), let field = blockField {
                if let value = unquoted(item.text), isMention(value) {
                    found.append(Mention(field: field, value: value))
                    if let target = visit(field, value) {
                        output[index] = item.prefix + quote(target)
                    }
                }
                continue
            }
            blockField = nil
            guard !line.hasPrefix(" "), !line.hasPrefix("#"), !line.hasPrefix("-"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard fields.contains(key) else { continue }
            let prefix = String(line[..<colon]) + ": "
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                blockField = key
            } else if rest.hasPrefix("["), rest.hasSuffix("]"), !rest.contains(" #") {
                output[index] = inlineList(rest, key: key, prefix: prefix, found: &found, visit: visit) ?? line
            } else if let value = scalarValue(rest), isMention(value) {
                found.append(Mention(field: key, value: value))
                if let target = visit(key, value) {
                    output[index] = prefix + quote(target) + comment(in: rest)
                }
            }
        }
        return (output, found)
    }

    private static func inlineList(
        _ rest: String,
        key: String,
        prefix: String,
        found: inout [Mention],
        visit: (String, String) -> String?
    ) -> String? {
        var items: [String] = []
        var changed = false
        for token in splitItems(String(rest.dropFirst().dropLast())) {
            guard let value = unquoted(token), isMention(value) else {
                items.append(token)
                continue
            }
            found.append(Mention(field: key, value: value))
            if let target = visit(key, value) {
                items.append(quote(target))
                changed = true
            } else {
                items.append(token)
            }
        }
        return changed ? prefix + "[" + items.joined(separator: ", ") + "]" : nil
    }

    private static func blockItem(_ line: String) -> (prefix: String, text: String)? {
        let trimmed = line.drop { $0 == " " }
        guard trimmed.hasPrefix("- ") else { return nil }
        let indent = line.prefix(line.count - trimmed.count)
        return (String(indent) + "- ", trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// Splits on commas that are not inside quotes.
    private static func splitItems(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current.trimmingCharacters(in: .whitespaces))
        return items.filter { !$0.isEmpty }
    }

    /// A plain or quoted scalar. `nil` for anything that is not one line of text (a map, a block).
    private static func scalarValue(_ rest: String) -> String? {
        guard let first = rest.first, !"{|>&*!%@`".contains(first), !rest.hasPrefix("[") else { return nil }
        if let value = unquoted(rest), rest.first == "\"" || rest.first == "'" {
            return value
        }
        let plain = rest.range(of: " #").map { String(rest[..<$0.lowerBound]) } ?? rest
        return plain.trimmingCharacters(in: .whitespaces)
    }

    private static func comment(in rest: String) -> String {
        guard rest.first != "\"", rest.first != "'", let range = rest.range(of: " #") else { return "" }
        return String(rest[range.lowerBound...])
    }

    private static func unquoted(_ token: String) -> String? {
        guard let first = token.first else { return nil }
        if first == "\"" || first == "'" {
            guard token.count >= 2, token.last == first else { return nil }
            return String(token.dropFirst().dropLast())
        }
        return token
    }

    private static func quote(_ target: String) -> String {
        let escaped = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"[[\(escaped)]]\""
    }
}
