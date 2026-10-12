@testable import FenCore
import Foundation
import Testing

/// Every file and folder under `root` (skipping `.git`) with its content, to prove nothing changed.
/// Features that touch a workspace reuse this to show they leave the folder alone (issue #9).
struct FolderSnapshot: Equatable {
    private let entries: [String: Data?]

    init(_ root: URL) throws {
        var found: [String: Data?] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [])
        while let url = walker?.nextObject() as? URL {
            let relative = String(url.path.dropFirst(root.path.count))
            if relative == "/.git" || relative.hasPrefix("/.git/") {
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory == true
            found[relative] = try isDirectory ? .some(nil) : .some(Data(contentsOf: url))
        }
        entries = found
    }

    var paths: [String] {
        entries.keys.sorted()
    }
}

@MainActor
@Suite("Storage rules (issue #9)", .serialized)
struct StorageRulesTests {
    private func makeHome() throws -> (TempFolder, FenHome) {
        let folder = try TempFolder("fenhome")
        return (folder, FenHome(root: folder.root.appendingPathComponent(".fen")))
    }

    private func fill(_ home: FenHome, id: UUID) throws {
        for directory in [home.indexDirectory(id: id), home.historyDirectory(id: id), home.modelsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appendingPathComponent("file"))
        }
        try Data("{}".utf8).write(to: home.workspacesFile)
        try Data("{}".utf8).write(to: home.aiProvidersFile)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("clear caches removes every index and keeps history, models, and settings")
    func clearCaches() throws {
        let (folder, home) = try makeHome()
        defer { folder.cleanUp() }
        let first = UUID()
        let second = UUID()
        try fill(home, id: first)
        try fill(home, id: second)

        #expect(try home.clearCaches() == 2)
        #expect(!exists(home.indexDirectory(id: first)) && !exists(home.indexDirectory(id: second)))
        #expect(exists(home.historyDirectory(id: first)) && exists(home.historyDirectory(id: second)))
        #expect(exists(home.modelsDirectory))
        #expect(exists(home.workspacesFile) && exists(home.aiProvidersFile))
        #expect(try home.clearCaches() == 0)
    }

    @Test("clear caches on a home that doesn't exist does nothing and creates nothing")
    func clearCachesWithoutHome() throws {
        let (folder, home) = try makeHome()
        defer { folder.cleanUp() }
        #expect(try home.clearCaches() == 0)
        #expect(!exists(home.root))
    }

    @Test("clearing history is separate, per workspace, and leaves the index")
    func clearHistory() throws {
        let (folder, home) = try makeHome()
        defer { folder.cleanUp() }
        let first = UUID()
        let second = UUID()
        try fill(home, id: first)
        try fill(home, id: second)

        try home.clearHistory(id: first)
        #expect(!exists(home.historyDirectory(id: first)))
        #expect(exists(home.historyDirectory(id: second)))
        #expect(exists(home.indexDirectory(id: first)))
        try home.clearHistory(id: first)
    }

    @Test("removing a workspace deletes its state folder and not the workspace")
    func removeDeletesState() throws {
        let (folder, home) = try makeHome()
        let repo = try TempFolder("repo")
        defer { folder.cleanUp()
            repo.cleanUp()
        }
        try repo.write("a.md")
        let registry = WorkspaceRegistry(home: home)
        let workspace = try registry.add(folder: repo.root)
        try fill(home, id: workspace.id)

        try registry.remove(id: workspace.id)
        #expect(!exists(home.workspaceDirectory(id: workspace.id)))
        #expect(exists(repo.root.appendingPathComponent("a.md")))
        #expect(exists(home.modelsDirectory))
    }

    // MARK: - Zero footprint in the folder

    private func makeRepo() throws -> TempFolder {
        let repo = try TempFolder("repo")
        try repo.write("README.md", "# Readme\n")
        try repo.write("docs/guide.md", "# Guide\n")
        try repo.write("notes/ideas.md", "# Ideas\n")
        try repo.write(".gitignore", "build/\n")
        try repo.initRepo()
        try repo.commitAll("init")
        return repo
    }

    private func waitUntilListed(_ library: WorkspaceLibrary, _ id: UUID) async throws -> Bool {
        try await pollUntilTrue {
            let state = library.state(for: id)
            return state.hasScanned && state.phase == .idle
        }
    }

    @Test("a workspace's whole life writes nothing into its folder and leaves git status clean")
    func zeroFootprint() async throws {
        let (homeFolder, home) = try makeHome()
        let repo = try makeRepo()
        defer { homeFolder.cleanUp()
            repo.cleanUp()
        }
        let before = try FolderSnapshot(repo.root)
        let library = WorkspaceLibrary(home: home, watching: false)

        let workspace = try library.add(folder: repo.root)
        #expect(try await waitUntilListed(library, workspace.id))
        try library.updateSettings(id: workspace.id) {
            $0.includeGlobs = ["docs/**"]
            $0.aiDataAccess = .anyConfiguredProvider
            $0.approvalMode = .autoApprove
        }
        #expect(try await waitUntilListed(library, workspace.id))
        library.refreshAll()
        #expect(try await waitUntilListed(library, workspace.id))
        try library.registry.clearCaches()

        #expect(try FolderSnapshot(repo.root) == before)
        #expect(try repo.git("status", "--porcelain").isEmpty)
        #expect(!exists(repo.root.appendingPathComponent(".fen")))

        try library.remove(id: workspace.id)
        #expect(try FolderSnapshot(repo.root) == before)
        #expect(try repo.git("status", "--porcelain").isEmpty)
    }

    @Test("with a workspace open, editing one note changes only that file in git")
    func editingTouchesOnlyTheNote() async throws {
        let (homeFolder, home) = try makeHome()
        let repo = try makeRepo()
        defer { homeFolder.cleanUp()
            repo.cleanUp()
        }
        let library = WorkspaceLibrary(home: home, watching: false)
        let workspace = try library.add(folder: repo.root)
        #expect(try await waitUntilListed(library, workspace.id))

        try Data("# Guide\n\nOne more line.\n".utf8)
            .write(to: repo.root.appendingPathComponent("docs/guide.md"), options: .atomic)
        library.scan(workspace.id)
        #expect(try await waitUntilListed(library, workspace.id))

        #expect(try repo.git("status", "--porcelain").trimmingCharacters(in: .whitespacesAndNewlines)
            == "M docs/guide.md")
        #expect(try repo.git("diff", "--numstat").trimmingCharacters(in: .whitespacesAndNewlines)
            == "2\t0\tdocs/guide.md")
    }

    @Test("the snapshot helper notices a stray file, so the tests above can fail")
    func snapshotDetectsChanges() throws {
        let repo = try makeRepo()
        defer { repo.cleanUp() }
        let before = try FolderSnapshot(repo.root)
        try repo.write(".fen/schema.yaml", "x")
        #expect(try FolderSnapshot(repo.root) != before)
        #expect(try repo.git("status", "--porcelain").contains(".fen/"))
    }
}
