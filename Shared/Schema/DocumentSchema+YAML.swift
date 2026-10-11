import Foundation
import Yams

public enum SchemaError: Error, Equatable, LocalizedError {
    case notYAML
    case missingVersion
    case badVersion(String)
    case badName(String)
    case duplicate(String)
    case badField(type: String, field: String, reason: String)
    /// A change that removes or alters something needs a new major version.
    case breakingNeedsMajor
    case versionNotRaised
    case outsideWorkspace

    public var errorDescription: String? {
        switch self {
        case .notYAML: "The schema file isn't valid YAML."
        case .missingVersion: "The schema file has no schema_version."
        case let .badVersion(text): "schema_version \"\(text)\" isn't a version like 1.0.0."
        case let .badName(name): "\"\(name)\" isn't a valid name. Use letters, digits, - and _."
        case let .duplicate(name): "\"\(name)\" appears twice."
        case let .badField(type, field, reason): "Field \(field) of \(type): \(reason)"
        case .breakingNeedsMajor: "This change removes or alters something. It needs a new major version."
        case .versionNotRaised: "The version must go up when the schema changes."
        case .outsideWorkspace: "The schema file must stay inside the workspace folder."
        }
    }
}

extension DocumentSchema {
    /// Reads a schema file. Unknown keys are ignored, so a newer minor version still loads.
    public init(yaml: String) throws {
        guard let root = try? Yams.compose(yaml: yaml), case let .mapping(top) = root else { throw SchemaError.notYAML }
        guard let versionNode = top["schema_version"], let versionText = versionNode.scalar?.string else {
            throw SchemaError.missingVersion
        }
        guard let version = SchemaVersion(versionText) else { throw SchemaError.badVersion(versionText) }
        var types: [DocumentType] = []
        if case let .mapping(typeMap)? = top["types"] {
            for (key, value) in typeMap {
                guard let name = key.scalar?.string, Self.isValidName(name) else {
                    throw SchemaError.badName(key.scalar?.string ?? "")
                }
                guard !types.contains(where: { $0.name == name }) else { throw SchemaError.duplicate(name) }
                try types.append(Self.parseType(name: name, node: value))
            }
        }
        self.init(version: version, types: types)
    }

    private static func parseType(name: String, node: Node) throws -> DocumentType {
        let map = node.mapping
        var type = DocumentType(
            name,
            description: map?["description"]?.scalar?.string ?? "",
            hidden: map?["hidden"]?.bool ?? false
        )
        if case let .mapping(fields)? = map?["fields"] {
            for (key, value) in fields {
                guard let fieldName = key.scalar?.string, isValidName(fieldName) else {
                    throw SchemaError.badName(key.scalar?.string ?? "")
                }
                guard type.field(named: fieldName) == nil else { throw SchemaError.duplicate("\(name).\(fieldName)") }
                try type.fields.append(parseField(type: name, name: fieldName, node: value))
            }
        }
        return type
    }

    private static func parseField(type: String, name: String, node: Node) throws -> SchemaField {
        let map = node.mapping
        let jsonType = map?["type"]?.scalar?.string ?? "string"
        var field = SchemaField(
            name,
            required: map?["required"]?.bool ?? false,
            description: map?["description"]?.scalar?.string ?? "",
            hidden: map?["hidden"]?.bool ?? false
        )
        if case let .sequence(items)? = map?["enum"] {
            field.values = items.compactMap(\.scalar?.string)
        }
        switch jsonType {
        case "string":
            if !field.values.isEmpty {
                field.kind = .choice
            } else if map?["format"]?.scalar?.string == "date" {
                field.kind = .date
            } else {
                field.kind = .text
            }
        case "number", "integer": field.kind = .number
        case "boolean": field.kind = .boolean
        case "array": field.kind = .list
        default: throw SchemaError.badField(type: type, field: name, reason: "type \"\(jsonType)\" isn't supported")
        }
        return field
    }

    /// The file text. Stable and plain, so it diffs well in git.
    public var yaml: String {
        var lines = [
            "# Document types for this workspace. Edit this file in any editor.",
            "# A document picks a type with `type: <name>` in its front matter.",
            "schema_version: \(version)",
            "types:",
        ]
        for type in types {
            lines.append("  \(type.name):")
            lines.append("    description: \(Self.text(type.description))")
            if type.hidden {
                lines.append("    hidden: true")
            }
            if !type.fields.isEmpty {
                lines.append("    fields:")
            }
            for field in type.fields {
                lines.append("      \(field.name):")
                lines += Self.yamlLines(for: field).map { "        " + $0 }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A YAML scalar on one line. A line break in a description becomes a space.
    private static func text(_ value: String) -> String {
        FrontMatterEditor.scalar(value.split(whereSeparator: \.isNewline).joined(separator: " "))
    }

    private static func yamlLines(for field: SchemaField) -> [String] {
        var lines: [String] = []
        switch field.kind {
        case .text: lines.append("type: string")
        case .date: lines += ["type: string", "format: date"]
        case .number: lines.append("type: number")
        case .boolean: lines.append("type: boolean")
        case .list: lines.append("type: array")
        case .choice:
            lines.append("type: string")
            lines.append("enum: [" + field.values.map(FrontMatterEditor.scalar).joined(separator: ", ") + "]")
        }
        if field.required {
            lines.append("required: true")
        }
        if !field.description.isEmpty {
            lines.append("description: \(text(field.description))")
        }
        if field.hidden {
            lines.append("hidden: true")
        }
        return lines
    }
}

private extension Node {
    var bool: Bool? {
        scalar.flatMap { Bool($0.string) }
    }
}
