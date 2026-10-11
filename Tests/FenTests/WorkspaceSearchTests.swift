@testable import FenCore
import Foundation
import Testing

@MainActor
private struct Harness {
    let home: TempHome
    let library: WorkspaceLibrary
    let embedder: FakeEmbedder

    init(gated: GatedEmbedder? = nil, watching: Bool = false) throws {
        home = try TempHome()
        embedder = FakeEmbedder()
        library = WorkspaceLibrary(home: home.home, watching: watching, embedder: gated ?? embedder)
    }

    func cleanUp() {
        home.cleanUp()
    }

    /// Waits until the workspace is listed and its index holds `documents` files and is idle.
    func indexed(_ id: UUID, documents: Int) async throws -> Bool {
        try await pollUntilTrue(timeout: .seconds(30)) {
            let status = library.indexStatus(for: id)
            return library.state(for: id).hasScanned && status.phase == .idle && status.documents == documents
        }
    }

    func found(
        _ query: String,
        scope: WorkspaceScope = .all,
        destination: ModelDestination? = nil
    ) async -> [SearchResult] {
        await library.search(query, scope: scope, destination: destination)
    }

    /// Waits until `path` is the best result for the query.
    func eventually(_ query: String, topIs path: String) async throws -> Bool {
        try await pollUntilTrue(timeout: .seconds(30)) {
            await library.search(query, scope: .all).first?.relativePath == path
        }
    }

    /// Waits until `path` is no longer a result for the query.
    func eventually(_ query: String, dropsOut path: String) async throws -> Bool {
        try await pollUntilTrue(timeout: .seconds(30)) {
            await !library.search(query, scope: .all).contains { $0.relativePath == path }
        }
    }
}

@Suite("Workspace search (issue #35)", .serialized)
@MainActor
struct WorkspaceSearchTests {
    @Test("adding a folder indexes it in the background, and search finds words without opening files")
    func wordsAcrossFiles() async throws {
        let harness = try Harness()
        let folder = try TempFolder("search")
        defer { harness.cleanUp()
            folder.cleanUp()
        }
        try folder.write("README.md", "# Readme\nWelcome to the project.\n")
        try folder.write("docs/release.md", "# Release\n## Signing\nNotarize the archive before upload.\n")
        try folder.write("docs/deep/more.md", "# More\nNothing relevant here.\n")
        let workspace = try harness.library.add(folder: folder.root, name: "Project")

        #expect(try await harness.indexed(workspace.id, documents: 3))
        let results = await harness.found("notarize archive")
        #expect(results.first?.relativePath == "docs/release.md")
        #expect(results.first?.workspaceName == "Project")
        #expect(results.first?.workspaceID == workspace.id)
        #expect(results.first?.heading == "Release > Signing")
        #expect(results.first?.snippet.contains("Notarize") == true)
        let status = harness.library.indexStatus(for: workspace.id)
        #expect(status.isSemantic)
        #expect(status.chunks == 3)
    }

    @Test("search matches meaning when no word is shared")
    func meaning() async throws {
        let harness = try Harness()
        let folder = try TempFolder("search-meaning")
        defer { harness.cleanUp()
            folder.cleanUp()
        }
        try folder.write("garage.md", "# Garage\nThe sedan needs new tires.\n")
        try folder.write("kitchen.md", "# Kitchen\nWe bake bread for dinner.\n")
        let workspace = try harness.library.add(folder: folder.root)
        #expect(try await harness.indexed(workspace.id, documents: 2))

        let results = await harness.found("automobile")
        #expect(results.first?.relativePath == "garage.md")
        #expect(results.first?.match == .meaning)
        #expect(!results.contains { $0.relativePath == "kitchen.md" })
    }

    @Test("scope can be one workspace, chosen workspaces, or all, and each result names its workspace")
    func scopes() async throws {
        let harness = try Harness()
        let one = try TempFolder("search-one")
        let two = try TempFolder("search-two")
        let three = try TempFolder("search-three")
        defer { harness.cleanUp()
            [one, two, three].forEach { $0.cleanUp() }
        }
        try one.write("a.md", "# A\nshared keyword here\n")
        try two.write("b.md", "# B\nshared keyword there\n")
        try three.write("c.md", "# C\nshared keyword elsewhere\n")
        let first = try harness.library.add(folder: one.root, name: "One")
        let second = try harness.library.add(folder: two.root, name: "Two")
        let third = try harness.library.add(folder: three.root, name: "Three")
        for workspace in [first, second, third] {
            #expect(try await harness.indexed(workspace.id, documents: 1))
        }

        let names: ([SearchResult]) -> [String] = { $0.map(\.workspaceName).sorted() }
        #expect(await names(harness.found("keyword", scope: .workspace(second.id))) == ["Two"])
        #expect(await names(harness.found("keyword", scope: .chosen([first.id, third.id]))) == ["One", "Three"])
        #expect(await names(harness.found("keyword", scope: .all)) == ["One", "Three", "Two"])
        #expect(await harness.found("keyword", scope: .chosen([])).isEmpty)
        #expect(await harness.found("keyword", scope: .workspace(UUID())).isEmpty)
    }

    @Test("a workspace whose AI data access forbids a destination is skipped when results feed a model")
    func dataAccess() async throws {
        let harness = try Harness()
        let open = try TempFolder("search-open")
        let local = try TempFolder("search-local")
        let closed = try TempFolder("search-closed")
        defer { harness.cleanUp()
            [open, local, closed].forEach { $0.cleanUp() }
        }
        try open.write("a.md", "# A\nsecret plan\n")
        try local.write("b.md", "# B\nsecret plan\n")
        try closed.write("c.md", "# C\nsecret plan\n")
        let anyProvider = try harness.library.add(folder: open.root, name: "Any")
        let localOnly = try harness.library.add(folder: local.root, name: "Local")
        let none = try harness.library.add(folder: closed.root, name: "None")
        try harness.library.updateSettings(id: anyProvider.id) { $0.aiDataAccess = .anyConfiguredProvider }
        try harness.library.updateSettings(id: localOnly.id) { $0.aiDataAccess = .localProvidersOnly }
        try harness.library.updateSettings(id: none.id) { $0.aiDataAccess = .none }
        for workspace in [anyProvider, localOnly, none] {
            #expect(try await harness.indexed(workspace.id, documents: 1))
        }

        let names: ([SearchResult]) -> [String] = { $0.map(\.workspaceName).sorted() }
        #expect(await names(harness.found("secret plan")) == ["Any", "Local", "None"])
        #expect(await names(harness.found("secret plan", destination: .local)) == ["Any", "Local"])
        #expect(await names(harness.found("secret plan", destination: .remote)) == ["Any"])
    }

    @Test("hidden, ignored, secret-looking, excluded and binary files are never indexed")
    func exclusions() async throws {
        let harness = try Harness()
        let repo = try TempFolder("search-excluded")
        defer { harness.cleanUp()
            repo.cleanUp()
        }
        try repo.write("keep.md", "# Keep\nneedle in the kept note\n")
        try repo.write(".hidden/note.md", "# Hidden\nneedle hidden\n")
        try repo.write("build/out.md", "# Out\nneedle ignored\n")
        try repo.write(".gitignore", "build/\n")
        try repo.write("credentials.md", "# Credentials\nneedle credentials\n")
        try repo.write("secrets.txt", "needle secrets\n")
        try repo.write("drafts/skip.md", "# Skip\nneedle excluded by glob\n")
        try repo.writeBytes("blob.md", [0, 1, 2, 0, 0, 0xFF, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65])
        try repo.initRepo()
        try repo.commitAll()
        let workspace = try harness.library.add(folder: repo.root)
        try harness.library.updateSettings(id: workspace.id) { $0.excludeGlobs = ["drafts/**"] }
        #expect(try await harness.indexed(workspace.id, documents: 1))
        #expect(await harness.found("needle").map(\.relativePath) == ["keep.md"])
    }

    @Test("indexing a git repo leaves git status clean and the folder unchanged; the index is under the home")
    func gitStaysClean() async throws {
        let harness = try Harness()
        let repo = try TempFolder("search-git")
        defer { harness.cleanUp()
            repo.cleanUp()
        }
        try repo.write("README.md", "# Readme\nhello\n")
        try repo.write("docs/a.md", "# A\nworld\n")
        try repo.write(".gitignore", "build/\n")
        try repo.initRepo()
        try repo.commitAll("init")
        let before = try FolderSnapshot(repo.root)

        let workspace = try harness.library.add(folder: repo.root)
        #expect(try await harness.indexed(workspace.id, documents: 2))
        try harness.library.refreshAll()
        #expect(try await harness.indexed(workspace.id, documents: 2))

        #expect(try repo.git("status", "--porcelain").isEmpty)
        #expect(try FolderSnapshot(repo.root) == before)
        let indexFile = harness.home.home.indexDirectory(id: workspace.id).appendingPathComponent(SearchIndex.fileName)
        #expect(FileManager.default.fileExists(atPath: indexFile.path))
    }

    @Test("a changed, added or deleted file shows up in search after a file event")
    func incrementalOnChange() async throws {
        let harness = try Harness()
        let folder = try TempFolder("search-change")
        defer { harness.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md", "# A\nalpha topic\n")
        try folder.write("b.md", "# B\nbeta topic\n")
        let workspace = try harness.library.add(folder: folder.root)
        #expect(try await harness.indexed(workspace.id, documents: 2))

        try folder.write("a.md", "# A\nomega topic\n")
        try folder.write("c.md", "# C\ngamma topic\n")
        try FileManager.default.removeItem(at: folder.root.appendingPathComponent("b.md"))
        harness.library.changesArrived(workspace.id, paths: ["a.md", "b.md", "c.md"])

        #expect(try await harness.eventually("omega", topIs: "a.md"))
        #expect(try await harness.eventually("gamma", topIs: "c.md"))
        #expect(try await harness.eventually("beta", dropsOut: "b.md"))
        #expect(try await harness.eventually("alpha", dropsOut: "a.md"))
    }

    @Test("a branch switch in git (HEAD changed) re-indexes the files that changed")
    func headChange() async throws {
        let harness = try Harness()
        let repo = try TempFolder("search-head")
        defer { harness.cleanUp()
            repo.cleanUp()
        }
        try repo.write("main.md", "# Main\nmainline words\n")
        try repo.initRepo()
        try repo.commitAll("main")
        try repo.git("checkout", "-b", "feature")
        try repo.write("feature.md", "# Feature\nbranch words\n")
        try repo.commitAll("feature")
        try repo.git("checkout", "main")
        let workspace = try harness.library.add(folder: repo.root)
        #expect(try await harness.indexed(workspace.id, documents: 1))
        #expect(await harness.found("branch").isEmpty)

        try repo.git("checkout", "feature")
        harness.library.changesArrived(workspace.id, paths: [".git/HEAD"])
        #expect(try await harness.eventually("branch", topIs: "feature.md"))
    }

    @Test("clear caches deletes the indexes, then Fen builds them again")
    func clearCaches() async throws {
        let harness = try Harness()
        let folder = try TempFolder("search-clear")
        defer { harness.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md", "# A\nalpha topic\n")
        let workspace = try harness.library.add(folder: folder.root)
        #expect(try await harness.indexed(workspace.id, documents: 1))
        let before = harness.embedder.calls

        #expect(try harness.library.clearCaches() == 1)
        #expect(try await harness.eventually("alpha", topIs: "a.md"))
        #expect(harness.embedder.calls > before)
        #expect(try await harness.indexed(workspace.id, documents: 1))
    }

    @Test("removing a workspace deletes its index and nothing recreates it")
    func removal() async throws {
        let harness = try Harness()
        let folder = try TempFolder("search-remove")
        defer { harness.cleanUp()
            folder.cleanUp()
        }
        for number in 0 ..< 30 {
            try folder.write("n\(number).md", "# N\(number)\nword\(number)\n")
        }
        let workspace = try harness.library.add(folder: folder.root)
        let directory = harness.home.home.workspaceDirectory(id: workspace.id)
        try library(harness, removes: workspace.id)
        #expect(try await pollUntilTrue {
            let scheduler = harness.library.scheduler
            let running = await scheduler.runningCount
            let pending = await scheduler.pendingCount
            return running == 0 && pending == 0
        })
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(await harness.found("word1").isEmpty)
    }

    private func library(_ harness: Harness, removes id: UUID) throws {
        try harness.library.remove(id: id)
    }

    @Test("canceling stops indexing and keeps its progress, and resuming finishes the job")
    func cancelAndResume() async throws {
        let gated = GatedEmbedder()
        let harness = try Harness(gated: gated)
        let folder = try TempFolder("search-cancel")
        defer { harness.cleanUp()
            folder.cleanUp()
        }
        for number in 0 ..< 50 {
            try folder.write("n\(number).md", "# N\(number)\nword\(number) filler text\n")
        }
        let workspace = try harness.library.add(folder: folder.root)
        #expect(try await pollUntilTrue {
            if case .indexing = harness.library.indexStatus(for: workspace.id).phase {
                return true
            }
            return false
        })
        harness.library.cancelIndexing(id: workspace.id)
        #expect(try await pollUntilTrue { harness.library.indexStatus(for: workspace.id).phase == .canceled })
        gated.open()
        harness.library.resumeIndexing(id: workspace.id)
        #expect(try await harness.indexed(workspace.id, documents: 50))
        #expect(await harness.found("word40").first?.relativePath == "n40.md")
    }

    @Test("indexing off turns the whole feature off and writes nothing")
    func indexingOff() async throws {
        let home = try TempHome()
        let folder = try TempFolder("search-off")
        defer { home.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md", "# A\nalpha\n")
        let library = WorkspaceLibrary(home: home.home, watching: false, indexing: false, embedder: FakeEmbedder())
        let workspace = try library.add(folder: folder.root)
        #expect(try await pollUntilTrue { library.state(for: workspace.id).hasScanned })
        #expect(!FileManager.default.fileExists(atPath: home.home.indexDirectory(id: workspace.id).path))
        #expect(await library.search("alpha", scope: .all).isEmpty)
    }

    @Test("an empty or blank query returns nothing and never touches an index")
    func blankQuery() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        #expect(await harness.found("").isEmpty)
        #expect(await harness.found("   \n").isEmpty)
        #expect(harness.embedder.calls == 0)
    }

    @Test("indexing and search never use the network")
    func noNetwork() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var checked = 0
        for folder in ["Shared/Search", "Shared/Workspaces"] {
            let walker = FileManager.default.enumerator(
                at: repoRoot.appendingPathComponent(folder),
                includingPropertiesForKeys: nil
            )
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                for word in ["URLSession", "NWConnection", "CFNetwork", "NLContextualEmbedding", "requestAssets"] {
                    #expect(!source.contains(word), "\(url.lastPathComponent) uses \(word)")
                }
                checked += 1
            }
        }
        #expect(checked > 20)
    }

    @Test("the Apple embedding provider is on-device and the registry accepts it")
    func appleProviderIsLocal() throws {
        let provider = AppleSentenceEmbeddingProvider()
        #expect(provider.runsOnDevice)
        #expect(provider.dimension == 512)
        let registry = EmbeddingProviderRegistry()
        try registry.register(provider)
    }
}
