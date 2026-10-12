import Foundation

/// Turns a model's structured answer into `EditOperation`s (issue #140). The answer is data.
/// Only the fixed operations below pass. Unknown operations, extra fields (a URL, a scope, a tool
/// name) and paths outside the run's scope are rejected, whatever the document text said.
public enum EditResultParser {
    public static let maxEdits = 100

    private static let fields: [String: (required: [String], all: Set<String>)] = [
        "createFile": (["path", "content"], ["op", "path", "content"]),
        "append": (["path", "text"], ["op", "path", "text"]),
        "setFrontMatter": (["path", "key", "value"], ["op", "path", "key", "value"]),
        "replaceText": (["path", "find", "with"], ["op", "path", "find", "with"]),
        "overwrite": (["path", "content"], ["op", "path", "content"]),
        "delete": (["path"], ["op", "path"]),
        "move": (["from", "to"], ["op", "from", "to"]),
    ]

    public static func parse(_ data: Data, scope: Set<String>) throws -> [EditOperation] {
        guard let root = try? JSONSerialization.jsonObject(with: stripFence(data)) as? [String: Any],
              let list = root["edits"] as? [[String: Any]] else { throw EditParseError.notJSON }
        if let extra = root.keys.first(where: { $0 != "edits" }) {
            throw EditParseError.unexpectedField(extra)
        }
        guard list.count <= maxEdits else { throw EditParseError.tooManyEdits }
        return try list.map { try operation(from: $0, scope: scope) }
    }

    private static func operation(from object: [String: Any], scope: Set<String>) throws -> EditOperation {
        guard let op = object["op"] as? String, let shape = fields[op] else {
            throw EditParseError.unknownOperation(String(describing: object["op"] ?? "none"))
        }
        if let extra = object.keys.sorted().first(where: { !shape.all.contains($0) }) {
            throw EditParseError.unexpectedField(extra)
        }
        var values: [String: String] = [:]
        for field in shape.required {
            guard let value = object[field] as? String else { throw EditParseError.missingField(op: op, field: field) }
            values[field] = value
        }
        let edit = build(op, values)
        if let outside = edit.paths.first(where: { !scope.contains($0) }) {
            throw EditParseError.outsideScope(outside)
        }
        return edit
    }

    private static func build(_ op: String, _ values: [String: String]) -> EditOperation {
        let path = values["path"] ?? ""
        switch op {
        case "createFile": return .createFile(path: path, content: values["content"] ?? "")
        case "append": return .append(path: path, text: values["text"] ?? "")
        case "setFrontMatter": return .setFrontMatter(
                path: path,
                key: values["key"] ?? "",
                value: values["value"] ?? ""
            )
        case "replaceText": return .replaceText(path: path, find: values["find"] ?? "", with: values["with"] ?? "")
        case "overwrite": return .overwrite(path: path, content: values["content"] ?? "")
        case "delete": return .delete(path: path)
        default: return .move(from: values["from"] ?? "", to: values["to"] ?? "")
        }
    }

    /// Models often wrap JSON in a Markdown fence.
    private static func stripFence(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("```") else { return data }
        text = String(text.drop { $0 != "\n" }.dropFirst())
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return Data(text.utf8)
    }
}
