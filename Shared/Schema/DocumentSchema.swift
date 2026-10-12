import Foundation

/// `major.minor.patch`. Minor versions only add things. A major version may remove or change them.
public struct SchemaVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard parts.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public var bumpedMinor: SchemaVersion {
        SchemaVersion(major, minor + 1, 0)
    }

    public var bumpedMajor: SchemaVersion {
        SchemaVersion(major + 1, 0, 0)
    }

    public static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// What a field holds. They map to JSON Schema: `date` is a string with `format: date`, and
/// `choice` is a string with an `enum` list.
public enum FieldKind: String, Sendable, CaseIterable {
    case text
    case date
    case number
    case boolean
    case list
    case choice

    public var title: String {
        switch self {
        case .text: "Text"
        case .date: "Date"
        case .number: "Number"
        case .boolean: "Yes or no"
        case .list: "List"
        case .choice: "Choice"
        }
    }
}

public struct SchemaField: Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: FieldKind
    public var required: Bool
    /// The allowed values of a `choice` field.
    public var values: [String]
    public var description: String
    /// Hidden fields stay in the file. They are not shown in the Properties panel.
    public var hidden: Bool

    public var id: String {
        name
    }

    public init(
        _ name: String,
        _ kind: FieldKind = .text,
        required: Bool = false,
        values: [String] = [],
        description: String = "",
        hidden: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.required = required
        self.values = values
        self.description = description
        self.hidden = hidden
    }
}

public struct DocumentType: Sendable, Equatable, Identifiable {
    public var name: String
    /// Plain words about what this kind of document is. Classification (#11) reads it.
    public var description: String
    public var fields: [SchemaField]
    public var hidden: Bool

    public var id: String {
        name
    }

    public init(_ name: String, description: String, fields: [SchemaField] = [], hidden: Bool = false) {
        self.name = name
        self.description = description
        self.fields = fields
        self.hidden = hidden
    }

    public func field(named name: String) -> SchemaField? {
        fields.first { $0.name == name }
    }
}

/// The document types of one workspace (issue #7). `version` is the version of your own types,
/// not of the file format: a breaking change to your types is a new major version of the same format.
public struct DocumentSchema: Sendable, Equatable {
    public var version: SchemaVersion
    public var types: [DocumentType]

    public init(version: SchemaVersion = SchemaVersion(1), types: [DocumentType]) {
        self.version = version
        self.types = types
    }

    public func type(named name: String) -> DocumentType? {
        types.first { $0.name == name }
    }

    /// Names a type or field may have: the same as a front matter key.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil
    }
}
