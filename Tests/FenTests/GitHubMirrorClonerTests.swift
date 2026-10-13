@testable import FenCore
import Foundation
import Testing

@MainActor
struct GitHubMirrorClonerTests {
    private let repo = GitHubRepo(owner: "octo", name: "notes")

    private struct Setup {
        let parent: TempFolder
        let home: TempHome
        let library: WorkspaceLibrary
        let github: FakeRepository
        let secrets: MemorySecretStore
        let cloner: GitHubMirrorCloner

        func cleanUp() {
            parent.cleanUp()
            home.cleanUp()
        }
    }

    private func make(_ remote: [String: String] = ["a.md": "one\n", "docs/b.md": "two\n"]) throws -> Setup {
        let parent = try TempFolder("mirror-clone")
        let home = try TempHome()
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: nil)
        let github = FakeRepository(remote)
        let secrets = MemorySecretStore()
        var mirror = GitHubMirror(home: home.home)
        mirror.remote = github
        mirror.secrets = secrets
        return Setup(
            parent: parent,
            home: home,
            library: library,
            github: github,
            secrets: secrets,
            cloner: GitHubMirrorCloner(library: library, mirror: mirror)
        )
    }

    @Test func cloneBecomesAWorkspaceWithItsFilesItsSavedStateAndTheToken() async throws {
        let setup = try make()
        defer { setup.cleanUp() }
        let workspace = try await setup.cloner.clone(repo, token: " github_pat_abc ", into: setup.parent.root)
        #expect(workspace.name == "notes" && setup.library.workspaces.count == 1)
        let folder = setup.parent.root.appendingPathComponent("notes")
        #expect(try String(contentsOf: folder.appendingPathComponent("docs/b.md"), encoding: .utf8) == "two\n")
        let state = setup.cloner.mirror.load(id: workspace.id)
        #expect(state?.commit == "commit-1" && state?.files.count == 2)
        #expect(try setup.secrets.read(account: repo.tokenAccount) == "github_pat_abc")
        // The folder holds only the repository's files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["a.md", "docs"])
    }

    @Test func aPublicRepositoryNeedsNoToken() async throws {
        let setup = try make()
        defer { setup.cleanUp() }
        _ = try await setup.cloner.clone(repo, token: "  ", into: setup.parent.root)
        #expect(setup.secrets.allSecrets.isEmpty)
    }

    @Test func aBroadTokenIsRefusedBeforeAnythingIsCreated() async throws {
        let setup = try make()
        defer { setup.cleanUp() }
        await #expect(throws: GitHubToken.Problem.classic) {
            try await setup.cloner.clone(repo, token: "ghp_broad", into: setup.parent.root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.parent.root.path).isEmpty)
        #expect(setup.library.workspaces.isEmpty && setup.secrets.allSecrets.isEmpty)
    }

    @Test func aFailedCopyRemovesTheFolderItMadeAndKeepsNoTokenOrWorkspace() async throws {
        let setup = try make()
        defer { setup.cleanUp() }
        setup.github.failNext(with: GitSync.SyncError.authFailed(repo.title))
        await #expect(throws: GitSync.SyncError.authFailed(repo.title)) {
            try await setup.cloner.clone(repo, token: "github_pat_abc", into: setup.parent.root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.parent.root.path).isEmpty)
        #expect(setup.library.workspaces.isEmpty && setup.secrets.allSecrets.isEmpty)
    }

    @Test func aFolderWithFilesIsNeverTouched() async throws {
        let setup = try make()
        defer { setup.cleanUp() }
        try setup.parent.write("notes/keep.md", "mine")
        await #expect(throws: GitHubCloner.CloneError.notEmpty("notes")) {
            try await setup.cloner.clone(repo, token: nil, into: setup.parent.root)
        }
        let kept = setup.parent.root.appendingPathComponent("notes/keep.md")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "mine")
        #expect(setup.library.workspaces.isEmpty)
    }

    @Test func aPathThatLeavesTheFolderStopsTheCloneAndLeavesNothingBehind() async throws {
        let setup = try make(["ok.md": "ok\n", "../evil.md": "evil\n"])
        defer { setup.cleanUp() }
        await #expect(throws: MirrorError.unsafePath("../evil.md")) {
            try await setup.cloner.clone(repo, token: nil, into: setup.parent.root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.parent.root.path).isEmpty)
        #expect(setup.library.workspaces.isEmpty)
    }
}
