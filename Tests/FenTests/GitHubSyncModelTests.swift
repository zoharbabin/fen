@testable import FenCore
import Foundation
import Testing

struct GitSyncErrorTests {
    private let sync = GitSync(git: GitFixture.tool, secrets: MemorySecretStore())

    @Test(arguments: [
        "remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/octo/notes.git/'",
        "remote: Permission to octo/notes.git denied to someone.\nfatal: unable to access: The requested URL returned error: 403",
        "remote: Repository not found.\nfatal: repository 'https://github.com/octo/notes.git/' not found",
        "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
    ])
    func refusedAccessAsksForAToken(stderr: String) {
        let out = GitTool.Output(status: 128, stdout: Data(), stderr: stderr)
        #expect(sync.error(from: out, repo: SyncFixture.repo, token: nil) == .authFailed("octo/notes"))
    }

    @Test func otherFailuresKeepGitsFirstLine() {
        let out = GitTool.Output(status: 128, stdout: Data(), stderr: "fatal: unable to resolve host\nmore")
        #expect(sync.error(from: out, repo: nil, token: nil) == .failed("fatal: unable to resolve host"))
    }

    @Test func theTokenNeverAppearsInAnError() {
        let out = GitTool.Output(status: 128, stdout: Data(), stderr: "fatal: bad header github_pat_secret123 sent")
        let error = sync.error(from: out, repo: nil, token: "github_pat_secret123")
        #expect(!error.localizedDescription.contains("github_pat_secret123"))
    }
}

@MainActor
struct GitHubClonerTests {
    private struct Setup {
        let fixture: SyncFixture
        let home: TempHome
        let library: WorkspaceLibrary
        let cloner: GitHubCloner
    }

    private func make() throws -> Setup {
        let fixture = try SyncFixture()
        let home = try TempHome()
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: nil)
        return Setup(
            fixture: fixture,
            home: home,
            library: library,
            cloner: GitHubCloner(library: library, sync: fixture.sync)
        )
    }

    @Test func cloneBecomesAWorkspaceAndSavesTheToken() async throws {
        let setup = try make()
        let (fixture, home, library, cloner) = (setup.fixture, setup.home, setup.library, setup.cloner)
        defer { fixture.cleanUp()
            home.cleanUp()
        }
        let parent = try fixture.folder.folder("parent")
        let workspace = try await cloner.clone(
            SyncFixture.repo, token: " github_pat_abc ", into: parent, remote: fixture.remote
        )
        #expect(workspace.name == "notes")
        #expect(library.workspaces.count == 1)
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("notes/a.md").path))
        #expect(fixture.secrets.allSecrets == ["github_pat_abc"])
    }

    @Test func theCloneRemembersHowToSync() async throws {
        let setup = try make()
        let (fixture, home, library, cloner) = (setup.fixture, setup.home, setup.library, setup.cloner)
        defer { fixture.cleanUp()
            home.cleanUp()
        }
        let parent = try fixture.folder.folder("parent")
        let workspace = try await cloner.clone(
            SyncFixture.repo, token: nil, into: parent, mode: .pushAsPR, remote: fixture.remote
        )
        #expect(workspace.settings.syncMode == .pushAsPR)
        #expect(library.registry.workspace(id: workspace.id)?.settings.syncMode == .pushAsPR)
        #expect(library.registry.workspace(id: workspace.id)?.settings.pushesAIChanges == false)
    }

    @Test func aBroadTokenIsRefusedBeforeAnythingIsCreated() async throws {
        let setup = try make()
        let (fixture, home, library, cloner) = (setup.fixture, setup.home, setup.library, setup.cloner)
        defer { fixture.cleanUp()
            home.cleanUp()
        }
        let parent = try fixture.folder.folder("parent")
        await #expect(throws: GitHubToken.Problem.classic) {
            try await cloner.clone(SyncFixture.repo, token: "ghp_broad", into: parent, remote: fixture.remote)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        #expect(library.workspaces.isEmpty)
        #expect(fixture.secrets.allSecrets.isEmpty)
    }

    @Test func aFailedCloneRemovesTheFolderItMadeAndKeepsNoToken() async throws {
        let setup = try make()
        let (fixture, home, library, cloner) = (setup.fixture, setup.home, setup.library, setup.cloner)
        defer { fixture.cleanUp()
            home.cleanUp()
        }
        let parent = try fixture.folder.folder("parent")
        await #expect(throws: GitSync.SyncError.self) {
            try await cloner.clone(
                SyncFixture.repo, token: "github_pat_abc", into: parent,
                remote: fixture.folder.root.appendingPathComponent("missing.git")
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        #expect(library.workspaces.isEmpty)
        #expect(fixture.secrets.allSecrets.isEmpty)
    }

    @Test func aFolderWithFilesIsNeverTouched() async throws {
        let setup = try make()
        let (fixture, home, library, cloner) = (setup.fixture, setup.home, setup.library, setup.cloner)
        defer { fixture.cleanUp()
            home.cleanUp()
        }
        let parent = try fixture.folder.folder("parent")
        let target = try fixture.folder.folder("parent/notes")
        try Data("mine".utf8).write(to: target.appendingPathComponent("keep.md"))
        await #expect(throws: GitHubCloner.CloneError.notEmpty("notes")) {
            try await cloner.clone(SyncFixture.repo, token: nil, into: parent, remote: fixture.remote)
        }
        #expect(try String(contentsOf: target.appendingPathComponent("keep.md"), encoding: .utf8) == "mine")
        #expect(library.workspaces.isEmpty)
    }

    @Test func cloningInsideAnotherWorkspaceIsRefusedAndCleanedUp() async throws {
        let setup = try make()
        let (fixture, home, library, cloner) = (setup.fixture, setup.home, setup.library, setup.cloner)
        defer { fixture.cleanUp()
            home.cleanUp()
        }
        let outer = try fixture.folder.folder("outer")
        try library.add(folder: outer, name: "Outer")
        await #expect(throws: WorkspaceError.self) {
            try await cloner.clone(SyncFixture.repo, token: nil, into: outer, remote: fixture.remote)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outer.path).isEmpty)
        #expect(library.workspaces.count == 1)
    }

    @Test func cloningTheSameRepoTwiceGivesTwoWorkspacesInDifferentFolders() async throws {
        let setup = try make()
        let (fixture, home, library, cloner) = (setup.fixture, setup.home, setup.library, setup.cloner)
        defer { fixture.cleanUp()
            home.cleanUp()
        }
        let one = try fixture.folder.folder("one")
        let two = try fixture.folder.folder("two")
        try await cloner.clone(SyncFixture.repo, token: nil, into: one, remote: fixture.remote)
        try await cloner.clone(SyncFixture.repo, token: nil, into: two, remote: fixture.remote)
        #expect(library.workspaces.count == 2)
    }

    @Test func aClonedWorkspaceIsListedAndFenWritesNothingIntoIt() async throws {
        let setup = try make()
        let (fixture, home, library, cloner) = (setup.fixture, setup.home, setup.library, setup.cloner)
        defer { fixture.cleanUp()
            home.cleanUp()
        }
        let parent = try fixture.folder.folder("parent")
        let workspace = try await cloner.clone(SyncFixture.repo, token: nil, into: parent, remote: fixture.remote)
        library.start()
        let listed = try await pollUntilTrue(timeout: .seconds(30)) {
            library.state(for: workspace.id).snapshot.documents.count == 2
        }
        try #require(listed)
        let root = parent.appendingPathComponent("notes")
        #expect(try fixture.git(root, "status", "--porcelain").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [".git", "a.md", "notes"])
    }
}

@MainActor
struct GitHubSyncModelTests {
    private final class Counter: @unchecked Sendable {
        var changes = 0
    }

    private func model(_ fixture: SyncFixture, root: URL, counter: Counter) -> GitHubSyncModel {
        GitHubSyncModel(sync: fixture.sync, root: { root }, changed: { counter.changes += 1 })
    }

    @Test func aFolderWithoutAGitHubOriginShowsNothing() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let root = try await fixture.clone("plain")
        let model = model(fixture, root: root, counter: Counter())
        await model.open()
        #expect(!model.isAvailable)
    }

    @Test func openingPullsNewCommitsAndTellsTheLibrary() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine", githubOrigin: true)
        let theirs = try await fixture.clone("theirs")
        try fixture.publish("c.md", "# C\n", from: theirs)
        let counter = Counter()
        let model = model(fixture, root: mine, counter: counter)
        await model.open()
        #expect(model.repo == SyncFixture.repo)
        #expect(counter.changes == 1)
        #expect(FileManager.default.fileExists(atPath: mine.appendingPathComponent("c.md").path))
        #expect(model.status?.isClean == true)
        #expect(model.message == nil)
    }

    @Test func syncPullsCommitsAndPushesInOrder() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine", githubOrigin: true)
        let theirs = try await fixture.clone("theirs")
        try fixture.publish("c.md", "# C\n", from: theirs)
        try Data("# A2\n".utf8).write(to: mine.appendingPathComponent("a.md"))
        let model = model(fixture, root: mine, counter: Counter())
        await model.open()
        await model.syncNow()
        #expect(model.message == nil)
        #expect(model.status?.isClean == true)
        #expect(try fixture.git(fixture.remote, "show", "main:a.md") == "# A2")
        #expect(try fixture.git(fixture.remote, "show", "main:c.md") == "# C")
    }

    @Test func syncStopsAndExplainsWhenBothSidesChanged() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine", githubOrigin: true)
        let theirs = try await fixture.clone("theirs")
        try Data("# mine\n".utf8).write(to: mine.appendingPathComponent("d.md"))
        try await fixture.sync.commitChanges(at: mine)
        try fixture.publish("c.md", "# C\n", from: theirs)
        let remoteHead = try fixture.git(fixture.remote, "rev-parse", "main")
        let model = model(fixture, root: mine, counter: Counter())
        await model.open()
        await model.syncNow()
        #expect(model.message?.contains("both have new commits") == true)
        #expect(try fixture.git(fixture.remote, "rev-parse", "main") == remoteHead)
    }

    @Test func aTokenIsCheckedBeforeItIsSaved() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine", githubOrigin: true)
        let model = model(fixture, root: mine, counter: Counter())
        await model.open()
        #expect(!model.saveToken("ghp_broad"))
        #expect(model.message?.contains("classic") == true)
        #expect(fixture.secrets.allSecrets.isEmpty)
        #expect(model.saveToken("github_pat_ok"))
        #expect(fixture.secrets.allSecrets == ["github_pat_ok"])
    }
}
