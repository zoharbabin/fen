import Foundation

/// Reads and writes `.fen/schema.yaml` in one workspace folder (issue #7).
///
/// This is the only file Fen puts inside a workspace, and only after you choose to create it
/// (docs/ARCHITECTURE.md, "Storage and git rules"). Every path goes through `PathGate`, so a
/// `.fen` folder that is a symlink out of the workspace is refused.
public struct SchemaStore: Sendable {
    public static let relativePath = ".fen/schema.yaml"
    /// A schema file larger than this is not read. Real ones are a few kilobytes.
    public static let maxBytes = 512 * 1024

    public struct Loaded: Sendable, Equatable {
        public let schema: DocumentSchema
        /// `false` while the workspace uses the built-in types because it has no schema file.
        public let hasFile: Bool
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var fileURL: URL? {
        PathGate.resolve(relativePath: Self.relativePath, in: root)
    }

    public var fileExists: Bool {
        fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The file's schema, or the built-in one when there is no file. Reading never creates anything.
    public func load() throws -> Loaded {
        guard let url = fileURL else { throw SchemaError.outsideWorkspace }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Loaded(schema: SchemaStarters.defaultSchema, hasFile: false)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxBytes, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SchemaError.notYAML
        }
        return try Loaded(schema: DocumentSchema(yaml: text), hasFile: true)
    }

    /// Writes `schema`. `previous` is what the workspace uses now. A breaking change is refused
    /// unless the major version went up, and any change must raise the version.
    public func save(_ schema: DocumentSchema, replacing previous: DocumentSchema) throws {
        try schema.validate()
        try SchemaDiff(from: previous, to: schema).validate(from: previous.version, to: schema.version)
        try write(schema)
    }

    /// Creates the file. Call it only after you confirmed. It never overwrites an existing file.
    public func create(_ schema: DocumentSchema) throws {
        try schema.validate()
        guard !fileExists else { return }
        try write(schema)
    }

    private func write(_ schema: DocumentSchema) throws {
        guard let url = fileURL else { throw SchemaError.outsideWorkspace }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(schema.yaml.utf8).write(to: url, options: .atomic)
    }
}

public extension DocumentSchema {
    /// Names are valid and unique, and a choice field has values. The parser checks the same
    /// rules, so a schema that saves also loads.
    func validate() throws {
        var typeNames = Set<String>()
        for type in types {
            guard Self.isValidName(type.name) else { throw SchemaError.badName(type.name) }
            guard typeNames.insert(type.name).inserted else { throw SchemaError.duplicate(type.name) }
            var fieldNames = Set<String>()
            for field in type.fields {
                guard Self.isValidName(field.name) else { throw SchemaError.badName(field.name) }
                guard fieldNames.insert(field.name).inserted else {
                    throw SchemaError.duplicate("\(type.name).\(field.name)")
                }
                if field.kind == .choice, field.values.isEmpty {
                    throw SchemaError.badField(type: type.name, field: field.name, reason: "a choice needs values")
                }
            }
        }
    }
}
