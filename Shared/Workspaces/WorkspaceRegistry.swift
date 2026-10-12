import Foundation
import Observation

/// The list of granted folders, saved at `~/.fen/workspaces.json` (issues #5, #9).
///
/// - Adding refuses overlaps, the home folder, a volume root, and Fen's own home.
/// - Removing deletes the workspace's state in `~/.fen` and never touches the folder.
/// - Nothing is written to disk until you add a workspace.
@MainActor @Observable
public final class WorkspaceRegistry {
    public private(set) var workspaces: [Workspace] = []
    /// `true` after `load()` found a file it couldn't read. Every save then throws, so the empty list
    /// never overwrites the saved one.
    public private(set) var isListUnreadable = false

    public let home: FenHome
    private let userHome: URL
    private var roots: [UUID: URL] = [:]

    private struct FileFormat: Codable {
        var version = 1
        var workspaces: [Workspace]
    }

    public init(home: FenHome, userHome: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home
        self.userHome = userHome
    }

    /// Reads the saved list. A missing file means no workspaces. A corrupt file throws and is left
    /// in place: until a later `load()` succeeds, every change throws `listUnreadable` instead of
    /// saving over it.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: home.workspacesFile.path) else {
            workspaces = []
            isListUnreadable = false
            return
        }
        do {
            let data = try Data(contentsOf: home.workspacesFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            workspaces = try decoder.decode(FileFormat.self, from: data).workspaces
        } catch {
            isListUnreadable = true
            throw error
        }
        isListUnreadable = false
        roots = [:]
    }

    // MARK: - Granting

    /// Throws the reason `folder` can't be a workspace, naming the workspace in the way.
    public func validate(folder: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceError.notAFolder
        }
        if let canonical = PathGate.canonicalURL(of: folder), canonical == PathGate.canonicalURL(of: userHome) {
            throw WorkspaceError.homeFolder
        }
        if isVolumeRoot(folder) {
            throw WorkspaceError.volumeRoot
        }
        if PathGate.overlaps(folder, home.root) {
            throw WorkspaceError.fenHome
        }
        for workspace in workspaces {
            guard let root = try? rootURL(for: workspace.id) else { continue }
            if PathGate.canonicalURL(of: root) == PathGate.canonicalURL(of: folder) {
                throw WorkspaceError.sameAsWorkspace(name: workspace.name)
            }
            if PathGate.isContained(folder, in: root) {
                throw WorkspaceError.insideWorkspace(name: workspace.name)
            }
            if PathGate.isContained(root, in: folder) {
                throw WorkspaceError.containsWorkspace(name: workspace.name)
            }
        }
    }

    /// Grants `folder` to Fen. `folder` comes from a picker, so it is already security-scoped.
    @discardableResult
    public func add(folder: URL, name: String? = nil) throws -> Workspace {
        let started = folder.startAccessingSecurityScopedResource()
        do {
            try validate(folder: folder)
            let bookmark = try FolderBookmark.create(for: folder)
            let workspace = Workspace(
                name: name ?? folder.lastPathComponent,
                path: folder.standardizedFileURL.path,
                bookmark: bookmark
            )
            workspaces.append(workspace)
            roots[workspace.id] = folder
            do {
                try save()
            } catch {
                workspaces.removeAll { $0.id == workspace.id }
                roots[workspace.id] = nil
                throw error
            }
            return workspace
        } catch {
            if started {
                folder.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    /// Removes the grant and the workspace's state in `~/.fen`. The folder is not touched.
    /// See `FenHome.clearCaches()`.
    @discardableResult
    public func clearCaches() throws -> Int {
        try home.clearCaches()
    }

    public func remove(id: UUID) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.unknownWorkspace }
        let removed = workspaces.remove(at: index)
        do {
            try save()
            try home.removeWorkspaceState(id: id)
        } catch {
            workspaces.insert(removed, at: index)
            throw error
        }
        roots.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    public func updateSettings(id: UUID, _ change: (inout WorkspaceSettings) -> Void) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.unknownWorkspace }
        let before = workspaces[index]
        change(&workspaces[index].settings)
        do {
            try save()
        } catch {
            workspaces[index] = before
            throw error
        }
    }

    // MARK: - Lookup

    public func workspace(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    /// The workspace whose root contains `url`, or `nil` for a document outside every workspace.
    public func workspace(containing url: URL) -> Workspace? {
        workspaces.first { workspace in
            guard let root = try? rootURL(for: workspace.id) else { return false }
            return PathGate.isContained(url, in: root)
        }
    }

    /// The folder for `id`, with access started. Resolves the bookmark first, then the saved path.
    public func rootURL(for id: UUID) throws -> URL {
        if let cached = roots[id] {
            return cached
        }
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.unknownWorkspace }
        let workspace = workspaces[index]
        if let bookmark = workspace.bookmark, let resolved = try? FolderBookmark.resolve(bookmark) {
            _ = resolved.url.startAccessingSecurityScopedResource()
            if resolved.isStale, let fresh = try? FolderBookmark.create(for: resolved.url) {
                workspaces[index].bookmark = fresh
                workspaces[index].path = resolved.url.standardizedFileURL.path
                try? save()
            }
            roots[id] = resolved.url
            return resolved.url
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceError.accessLost(name: workspace.name)
        }
        let url = URL(fileURLWithPath: workspace.path, isDirectory: true)
        roots[id] = url
        return url
    }

    // MARK: - Private

    private func save() throws {
        guard !isListUnreadable else { throw WorkspaceError.listUnreadable }
        try home.ensureExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(FileFormat(workspaces: workspaces))
        try data.write(to: home.workspacesFile, options: .atomic)
    }

    private func isVolumeRoot(_ url: URL) -> Bool {
        guard let canonical = PathGate.canonicalURL(of: url) else { return false }
        if canonical.path == "/" {
            return true
        }
        guard let volume = try? canonical.resourceValues(forKeys: [.volumeURLKey]).volume,
              let volumeRoot = PathGate.canonicalURL(of: volume) else { return false }
        return volumeRoot == canonical
    }
}

/// Security-scoped bookmarks keep a grant across launches in a sandbox and on iOS.
enum FolderBookmark {
    #if os(macOS)
        private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
        private static let createOptions: URL.BookmarkCreationOptions = []
        private static let resolveOptions: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif

    static func create(for url: URL) throws -> Data {
        try url.bookmarkData(options: createOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: resolveOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}
