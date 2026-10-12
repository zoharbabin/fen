import Foundation

/// A schema you are editing in the settings sheet (issue #7). Every type and field has a stable
/// id, so a text field keeps focus while you rename it. `schema` turns it back into the model.
public struct SchemaDraft: Equatable, Sendable {
    public struct Field: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var kind: FieldKind
        public var required: Bool
        public var description: String
        public var hidden: Bool
        /// The allowed values of a choice, comma separated.
        public var valuesText: String
    }

    public struct TypeDraft: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var description: String
        public var hidden: Bool
        public var fields: [Field]
    }

    public var version: SchemaVersion
    public var types: [TypeDraft]

    public init(_ schema: DocumentSchema) {
        version = schema.version
        types = schema.types.map(Self.draft(of:))
    }

    public var schema: DocumentSchema {
        DocumentSchema(version: version, types: types.map(Self.type(from:)))
    }

    private static func draft(of type: DocumentType) -> TypeDraft {
        TypeDraft(
            id: UUID(),
            name: type.name,
            description: type.description,
            hidden: type.hidden,
            fields: type.fields.map(draft(of:))
        )
    }

    private static func draft(of field: SchemaField) -> Field {
        Field(
            id: UUID(),
            name: field.name,
            kind: field.kind,
            required: field.required,
            description: field.description,
            hidden: field.hidden,
            valuesText: field.values.joined(separator: ", ")
        )
    }

    private static func type(from draft: TypeDraft) -> DocumentType {
        DocumentType(
            draft.name,
            description: draft.description,
            fields: draft.fields.map(field(from:)),
            hidden: draft.hidden
        )
    }

    private static func field(from draft: Field) -> SchemaField {
        SchemaField(
            draft.name,
            draft.kind,
            required: draft.required,
            values: values(draft.valuesText),
            description: draft.description,
            hidden: draft.hidden
        )
    }

    private static func values(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in text.split(separator: ",") {
            let value = part.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    /// What stops this draft from being saved, in words. Empty when it can be saved.
    public var problems: [String] {
        var problems: [String] = []
        var typeNames = Set<String>()
        for type in types {
            if !DocumentSchema.isValidName(type.name) {
                problems.append("\"\(type.name)\" isn't a valid type name. Use letters, digits, - and _.")
            } else if !typeNames.insert(type.name).inserted {
                problems.append("The type \(type.name) appears twice.")
            }
            var fieldNames = Set<String>()
            for field in type.fields {
                if !DocumentSchema.isValidName(field.name) {
                    problems.append("\(type.name): \"\(field.name)\" isn't a valid field name.")
                } else if !fieldNames.insert(field.name).inserted {
                    problems.append("\(type.name): the field \(field.name) appears twice.")
                }
                if field.kind == .choice, Self.values(field.valuesText).isEmpty {
                    problems.append("\(type.name).\(field.name): a choice needs at least one value.")
                }
            }
        }
        return problems
    }

    // MARK: - Editing

    @discardableResult
    public mutating func addType() -> UUID {
        let type = TypeDraft(
            id: UUID(),
            name: uniqueName("NewType", among: types.map(\.name)),
            description: "",
            hidden: false,
            fields: []
        )
        types.append(type)
        return type.id
    }

    public mutating func addField(toType id: UUID) {
        guard let index = types.firstIndex(where: { $0.id == id }) else { return }
        let name = uniqueName("new_field", among: types[index].fields.map(\.name))
        types[index].fields.append(Field(
            id: UUID(), name: name, kind: .text, required: false, description: "", hidden: false, valuesText: ""
        ))
    }

    public mutating func removeType(_ id: UUID) {
        types.removeAll { $0.id == id }
    }

    public mutating func removeField(_ fieldID: UUID, fromType id: UUID) {
        guard let index = types.firstIndex(where: { $0.id == id }) else { return }
        types[index].fields.removeAll { $0.id == fieldID }
    }

    /// Adds the types of a starter pack that the draft doesn't have yet. Your own types are kept.
    public mutating func add(_ pack: SchemaStarters.Pack) {
        let have = Set(types.map(\.name))
        let fresh = pack.types.filter { !have.contains($0.name) }
        types += SchemaDraft(DocumentSchema(version: version, types: fresh)).types
    }

    private func uniqueName(_ base: String, among names: [String]) -> String {
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base)\(number)") {
            number += 1
        }
        return "\(base)\(number)"
    }
}
