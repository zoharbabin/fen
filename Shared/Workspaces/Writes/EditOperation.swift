import Foundation

/// How much an edit can hurt (issue #140).
public enum EditTier: String, Codable, Sendable, Comparable {
    /// Adds text or a file. Nothing existing changes.
    case additive
    /// Changes existing text. The pre-image makes it reversible.
    case replacing
    /// Deletes, renames, moves, or overwrites a whole file. Always asks.
    case destructive

    private var rank: Int {
        switch self {
        case .additive: 0
        case .replacing: 1
        case .destructive: 2
        }
    }

    public static func < (lhs: EditTier, rhs: EditTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Lines to add right below one existing line.
public struct LineInsertion: Sendable, Equatable {
    /// The whole text of the line to add below. It must occur exactly once in the file.
    public var anchor: String
    /// The lines to add, joined with line breaks.
    public var text: String

    public init(anchor: String, text: String) {
        self.anchor = anchor
        self.text = text
    }
}

/// The fixed set of things an AI result may ask Fen to do. Anything else is rejected before it
/// reaches the gate. Paths are relative to the workspace root.
public enum EditOperation: Sendable, Equatable {
    case createFile(path: String, content: String)
    case append(path: String, text: String)
    /// Adds lines below existing lines. No existing line changes. Fen builds these itself, such as
    /// Enrich (issue #6). A model's result can't ask for one.
    case insertBelow(path: String, insertions: [LineInsertion])
    /// Sets one single-line front matter key. Every other byte of the file stays as it was.
    case setFrontMatter(path: String, key: String, value: String)
    /// Replaces text that occurs exactly once.
    case replaceText(path: String, find: String, with: String)
    case overwrite(path: String, content: String)
    case delete(path: String)
    case move(from: String, to: String)

    public var name: String {
        switch self {
        case .createFile: "createFile"
        case .append: "append"
        case .insertBelow: "insertBelow"
        case .setFrontMatter: "setFrontMatter"
        case .replaceText: "replaceText"
        case .overwrite: "overwrite"
        case .delete: "delete"
        case .move: "move"
        }
    }

    /// Every workspace path the edit touches.
    public var paths: [String] {
        switch self {
        case let .createFile(path, _), let .append(path, _), let .insertBelow(path, _), let .setFrontMatter(path, _, _),
             let .replaceText(path, _, _), let .overwrite(path, _), let .delete(path):
            [path]
        case let .move(from, to):
            [from, to]
        }
    }

    /// The file whose bytes the edit reads first.
    public var primaryPath: String {
        paths[0]
    }
}

/// Who and what produced a change. Goes into the activity log and the commit trailer.
public struct Provenance: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String
    /// Workspace paths the result was built from.
    public var sources: [String]

    public init(provider: String, model: String, sources: [String] = []) {
        self.provider = provider
        self.model = model
        self.sources = sources
    }

    /// A git trailer line. Add it to a commit message you write yourself. Fen never commits for you.
    public var commitTrailer: String {
        let clean = { (text: String) in text.replacingOccurrences(of: "\n", with: " ") }
        return "AI-Assisted-By: \(clean(provider)) \(clean(model))"
    }
}

/// One change an AI feature wants to make.
public struct ProposedChange: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var workspaceID: UUID
    /// Groups the changes of one run, for "revert this run".
    public var runID: UUID
    /// The feature that proposed it, such as `enrich`. Operation overrides match on this.
    public var operation: String
    public var documentType: String?
    /// The MCP client that asked, if any.
    public var client: String?
    public var edit: EditOperation
    /// The paths the run was allowed to touch. An edit outside this set is refused.
    public var scope: Set<String>
    /// Hash of the target as the result was computed (`nil` when the file didn't exist).
    /// The write is refused if the file has changed since.
    public var baseHash: String?
    /// You started this change yourself, so invoking it counts as approval for it (not for a
    /// destructive one).
    public var invokedByUser: Bool
    public var provenance: Provenance

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        runID: UUID = UUID(),
        operation: String,
        documentType: String? = nil,
        client: String? = nil,
        edit: EditOperation,
        scope: Set<String>,
        baseHash: String?,
        invokedByUser: Bool = false,
        provenance: Provenance
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.runID = runID
        self.operation = operation
        self.documentType = documentType
        self.client = client
        self.edit = edit
        self.scope = scope
        self.baseHash = baseHash
        self.invokedByUser = invokedByUser
        self.provenance = provenance
    }
}
