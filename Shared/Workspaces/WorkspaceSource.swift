import Foundation

/// A file Fen lists and processes in a workspace.
public struct WorkspaceFile: Sendable, Hashable, Identifiable {
    /// Path below the workspace root, with `/` separators.
    public let relativePath: String
    public let size: Int
    public let modified: Date
    /// `.fen/schema.yaml` (#7). It is always read, though hidden files are not.
    public let isSchema: Bool

    public var id: String {
        relativePath
    }

    public var name: String {
        (relativePath as NSString).lastPathComponent
    }

    public var folder: String {
        (relativePath as NSString).deletingLastPathComponent
    }

    public init(relativePath: String, size: Int, modified: Date, isSchema: Bool = false) {
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.isSchema = isSchema
    }
}

/// Why a file isn't listed. Shown by "Why isn't this file here?" and checked by tests.
public enum ExclusionReason: String, Sendable, Equatable, Error {
    case hidden
    case gitignored
    case secretLooking
    case excludedByGlob
    case notIncluded
    case symlinkOutsideRoot
    case tooLarge
    case binary
    case notAFile
    case outsideRoot
}

/// Everything a scan found in one workspace.
public struct WorkspaceSnapshot: Sendable, Equatable {
    public var files: [String: WorkspaceFile] = [:]
    public var git: GitRepositoryState?

    public init() {}

    /// Files in path order, without the schema file.
    public var documents: [WorkspaceFile] {
        files.values.filter { !$0.isSchema }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    public var schemaFile: WorkspaceFile? {
        files.values.first(where: \.isSchema)
    }

    mutating func removeAll(under path: String) {
        files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }
}

/// Where a workspace's files come from. A local folder is the first source. A GitHub-backed
/// workspace (#60) plugs in here without changing the callers.
public protocol WorkspaceSource: Sendable {
    var rootURL: URL { get }

    /// Lists every eligible file. Cancelable. `progress` gets the running file count.
    func scan(progress: @Sendable (Int) -> Void) async throws -> WorkspaceSnapshot

    /// Applies file-system changes to `snapshot`. `paths` are relative to the root.
    func update(_ snapshot: WorkspaceSnapshot, changedPaths paths: [String]) async throws -> WorkspaceSnapshot

    /// Branch and dirty state, or `nil` when the root isn't in a git work tree.
    func gitState(for snapshot: WorkspaceSnapshot) -> GitRepositoryState?

    /// The one gate to a file's location on disk. `nil` if the path leaves the root.
    func fileURL(forRelativePath path: String) -> URL?

    /// Reads one eligible file through the gate.
    func read(relativePath path: String) throws -> Data

    /// `nil` when the file is eligible.
    func exclusionReason(forRelativePath path: String) -> ExclusionReason?
}
