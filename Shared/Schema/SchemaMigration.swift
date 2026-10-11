import Foundation

/// A field that changed its name between two major versions of a schema.
public struct FieldRename: Sendable, Equatable {
    public var type: String
    public var from: String
    public var to: String

    public init(type: String, from: String, to: String) {
        self.type = type
        self.from = from
        self.to = to
    }
}

/// What a rename would do to your documents, shown before anything is written (issue #7).
public struct MigrationPreview: Sendable, Equatable {
    public struct Impact: Sendable, Equatable, Identifiable {
        public var id: String {
            relativePath
        }

        public let relativePath: String
        /// The renames this document gets. One document is one change, even with several renames.
        public let renames: [FieldRename]
        /// The front matter before and after. The write replaces `before` with `after`.
        public let before: String
        public let after: String
    }

    public var impacts: [Impact] = []
    /// Documents that already have both names. Fen leaves them alone.
    public var conflicts: [String] = []
    /// Files that were too large or not readable text.
    public var skipped: [String] = []

    public var isEmpty: Bool {
        impacts.isEmpty
    }
}

public enum SchemaMigration {
    /// Files larger than this are skipped, as the editor skips them for related-document search.
    static let maxBytes = 2 * 1024 * 1024

    /// The renames that turn `old` into `new`: a field that disappeared from a type and a field
    /// of the same kind that appeared in it. Fen only suggests these. You confirm or drop each.
    public static func suggestedRenames(from old: DocumentSchema, to new: DocumentSchema) -> [FieldRename] {
        var renames: [FieldRename] = []
        for oldType in old.types {
            guard let newType = new.type(named: oldType.name) else { continue }
            let gone = oldType.fields.filter { newType.field(named: $0.name) == nil }
            var added = newType.fields.filter { oldType.field(named: $0.name) == nil }
            for field in gone {
                guard let index = added.firstIndex(where: { $0.kind == field.kind }) else { continue }
                renames.append(FieldRename(type: oldType.name, from: field.name, to: added.remove(at: index).name))
            }
        }
        return renames
    }

    /// Reads each document and lists the ones a rename would change. Call it off the main thread.
    /// Reads go through `PathGate`, so nothing outside `root` is opened. It writes nothing.
    public static func preview(renames: [FieldRename], paths: [String], root: URL) -> MigrationPreview {
        var preview = MigrationPreview()
        let renderer = MarkdownRenderer()
        for path in paths {
            guard let url = PathGate.resolve(relativePath: path, in: root),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                preview.skipped.append(path)
                continue
            }
            guard text.hasPrefix("---"), let front = renderer.peekFrontMatter(text),
                  let type = DocumentProperties.typeName(in: front) else { continue }
            var current = text
            var applied: [FieldRename] = []
            for rename in renames where rename.type == type && front[rename.from] != nil {
                if front[rename.to] != nil {
                    if !preview.conflicts.contains(path) {
                        preview.conflicts.append(path)
                    }
                } else if let renamed = try? FrontMatterEditor.renameKey(from: rename.from, to: rename.to, in: current),
                          renamed != current {
                    current = renamed
                    applied.append(rename)
                }
            }
            if !applied.isEmpty, let before = FrontMatterEditor.head(of: text),
               let after = FrontMatterEditor.head(of: current) {
                preview.impacts.append(.init(relativePath: path, renames: applied, before: before, after: after))
            }
        }
        return preview
    }

    public struct Result: Sendable, Equatable {
        public var runID: UUID
        public var applied: Int
        /// Path and why it was not changed.
        public var failures: [String]
    }

    /// Applies a preview you approved. Each document is one undoable change in the activity log,
    /// and all of them share a run, so "revert this run" undoes the lot.
    @MainActor
    public static func apply(_ preview: MigrationPreview, workspaceID: UUID, gate: WriteGate) -> Result {
        var result = Result(runID: UUID(), applied: 0, failures: [])
        for impact in preview.impacts {
            let path = impact.relativePath
            do {
                let change = try ProposedChange(
                    workspaceID: workspaceID,
                    runID: result.runID,
                    operation: "schema-migration",
                    documentType: impact.renames.first?.type,
                    edit: .replaceText(path: path, find: impact.before, with: impact.after),
                    scope: [path],
                    baseHash: gate.contentHash(workspaceID: workspaceID, relativePath: path),
                    invokedByUser: true,
                    provenance: Provenance(provider: "Fen", model: "schema migration", sources: [path])
                )
                switch try gate.submit(change) {
                case .applied: result.applied += 1
                case .pending: result.failures.append("\(path): waiting for approval in Activity")
                case .blocked: result.failures.append("\(path): blocked by the write rules")
                }
            } catch {
                result.failures.append("\(path): \(error.localizedDescription)")
            }
        }
        return result
    }
}
