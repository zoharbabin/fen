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

    public var aiProvidersFile: URL {
        root.appendingPathComponent("ai-providers.json")
    }

    /// The global switch that pauses every auto-approve (issue #140).
    public var writePolicyFile: URL {
        root.appendingPathComponent("write-policy.json")
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

    public func activityLogFile(id: UUID) -> URL {
        historyDirectory(id: id).appendingPathComponent("activity.jsonl")
    }

    /// Copies of files as they were before an AI change, named `<path hash>-<content hash>`.
    public func preImagesDirectory(id: UUID) -> URL {
        historyDirectory(id: id).appendingPathComponent("preimages", isDirectory: true)
    }

    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Deletes every workspace's `index/` folder. Fen rebuilds them. History, models, settings and
    /// the provider list stay. Returns how many were removed.
    @discardableResult
    public func clearCaches() throws -> Int {
        let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: workspaces,
            includingPropertiesForKeys: nil
        )
        else { return 0 }
        var removed = 0
        for folder in folders {
            let index = folder.appendingPathComponent("index", isDirectory: true)
            if FileManager.default.fileExists(atPath: index.path) {
                try FileManager.default.removeItem(at: index)
                removed += 1
            }
        }
        return removed
    }

    /// Deletes one workspace's pre-images and activity log. This is data worth keeping, so call it
    /// only from an action that warns first.
    public func clearHistory(id: UUID) throws {
        let directory = historyDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Deletes one workspace's state. Never touches the workspace folder.
    public func removeWorkspaceState(id: UUID) throws {
        let directory = workspaceDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
