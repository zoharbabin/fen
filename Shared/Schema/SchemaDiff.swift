import Foundation

/// What changed between two schemas, and whether the change is safe (issue #7).
///
/// A minor version may only add. Anything that removes or tightens a type or field is breaking
/// and needs a new major version, after the user has seen a preview.
public struct SchemaDiff: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        // Additive
        case typeAdded(String)
        case fieldAdded(type: String, field: String)
        case valueAdded(type: String, field: String, value: String)
        case requirementRelaxed(type: String, field: String)
        case textChanged(type: String, field: String?)
        // Breaking
        case typeRemoved(String)
        case fieldRemoved(type: String, field: String)
        case kindChanged(type: String, field: String)
        case valueRemoved(type: String, field: String, value: String)
        case requirementAdded(type: String, field: String)

        /// A plain sentence for the review list.
        public var summary: String {
            switch self {
            case let .typeAdded(type): "Adds the type \(type)."
            case let .fieldAdded(type, field): "Adds the field \(field) to \(type)."
            case let .valueAdded(type, field, value): "Allows \"\(value)\" in \(type).\(field)."
            case let .requirementRelaxed(type, field): "\(type).\(field) is no longer required."
            case let .textChanged(type, field):
                "Changes the description or visibility of \(field.map { "\(type).\($0)" } ?? type)."
            case let .typeRemoved(type): "Removes the type \(type). Documents keep their text and open normally."
            case let .fieldRemoved(type, field): "Removes the field \(field) from \(type). Documents keep the value."
            case let .kindChanged(type, field): "Changes what kind of value \(type).\(field) holds."
            case let .valueRemoved(type, field, value): "No longer allows \"\(value)\" in \(type).\(field)."
            case let .requirementAdded(type, field): "\(type).\(field) is now required."
            }
        }

        public var isBreaking: Bool {
            switch self {
            case .typeRemoved, .fieldRemoved, .kindChanged, .valueRemoved, .requirementAdded: true
            case .typeAdded, .fieldAdded, .valueAdded, .requirementRelaxed, .textChanged: false
            }
        }
    }

    public let changes: [Change]

    public var isEmpty: Bool {
        changes.isEmpty
    }

    public var isBreaking: Bool {
        changes.contains { $0.isBreaking }
    }

    public init(from old: DocumentSchema, to new: DocumentSchema) {
        var changes: [Change] = []
        for oldType in old.types where new.type(named: oldType.name) == nil {
            changes.append(.typeRemoved(oldType.name))
        }
        for newType in new.types {
            guard let oldType = old.type(named: newType.name) else {
                changes.append(.typeAdded(newType.name))
                continue
            }
            changes += Self.typeChanges(from: oldType, to: newType)
        }
        self.changes = changes
    }

    private static func typeChanges(from old: DocumentType, to new: DocumentType) -> [Change] {
        var changes: [Change] = []
        if old.description != new.description || old.hidden != new.hidden {
            changes.append(.textChanged(type: new.name, field: nil))
        }
        for oldField in old.fields where new.field(named: oldField.name) == nil {
            changes.append(.fieldRemoved(type: old.name, field: oldField.name))
        }
        for newField in new.fields {
            guard let oldField = old.field(named: newField.name) else {
                // A new required field breaks every existing document of the type.
                changes.append(newField.required
                    ? .requirementAdded(type: new.name, field: newField.name)
                    : .fieldAdded(type: new.name, field: newField.name))
                continue
            }
            changes += fieldChanges(from: oldField, to: newField, in: new.name)
        }
        return changes
    }

    private static func fieldChanges(from old: SchemaField, to new: SchemaField, in type: String) -> [Change] {
        if old.kind != new.kind {
            return [.kindChanged(type: type, field: new.name)]
        }
        var changes: [Change] = []
        for value in old.values where !new.values.contains(value) {
            changes.append(.valueRemoved(type: type, field: new.name, value: value))
        }
        for value in new.values where !old.values.contains(value) {
            changes.append(.valueAdded(type: type, field: new.name, value: value))
        }
        if !old.required, new.required {
            changes.append(.requirementAdded(type: type, field: new.name))
        } else if old.required, !new.required {
            changes.append(.requirementRelaxed(type: type, field: new.name))
        }
        if old.description != new.description || old.hidden != new.hidden {
            changes.append(.textChanged(type: type, field: new.name))
        }
        return changes
    }

    /// The version a saved change must carry. `nil` means the change needs the user to pick a major
    /// version, so the caller shows the migration preview first.
    public func autoVersion(after current: SchemaVersion) -> SchemaVersion? {
        if isEmpty {
            return current
        }
        return isBreaking ? nil : current.bumpedMinor
    }

    /// Whether `new` may be saved as `version`. A breaking change must raise the major version.
    public func validate(from oldVersion: SchemaVersion, to newVersion: SchemaVersion) throws {
        if isEmpty {
            return
        }
        guard newVersion > oldVersion else { throw SchemaError.versionNotRaised }
        if isBreaking, newVersion.major <= oldVersion.major {
            throw SchemaError.breakingNeedsMajor
        }
    }
}
