import Foundation

/// Where Fen keeps its own state: `~/.fen` (issue #9). Per device, never synced or committed.
///
/// `~` is the app container in a sandboxed macOS build and on iOS, so the layout is the same at
/// a different absolute path. The root is a parameter everywhere, so tests never touch the real
/// one. Nothing is created on disk until something writes (`ensureExists()`).
public struct FenHome: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The real `~/.fen`. Only the app entry points should use this.
    public static var standard: FenHome {
        FenHome(root: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".fen"))
    }

    public var workspacesFile: URL {
        root.appendingPathComponent("workspaces.json")
    }

    public var modelsDirectory: URL {
        root.appendingPathComponent("models", isDirectory: true)
    }

    public func workspaceDirectory(id: UUID) -> URL {
        root.appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    public func indexDirectory(id: UUID) -> URL {
        workspaceDirectory(id: id).appendingPathComponent("index", isDirectory: true)
    }

    public func historyDirectory(id: UUID) -> URL {
        workspaceDirectory(id: id).appendingPathComponent("history", isDirectory: true)
    }

    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Deletes one workspace's state. Never touches the workspace folder.
    public func removeWorkspaceState(id: UUID) throws {
        let directory = workspaceDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
