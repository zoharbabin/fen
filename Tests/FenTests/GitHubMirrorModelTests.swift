@testable import FenCore
import Foundation
import Testing

@MainActor
struct GitHubMirrorModelTests {
    private let repo = GitHubRepo(owner: "octo", name: "notes")

    private struct Setup {
        let folder: TempFolder
        let home: TempFolder
        let github: FakeRepository
        let secrets: MemorySecretStore
        let model: GitHubMirrorModel
        let reloads: Counter

        func cleanUp() {
            folder.cleanUp()
            home.cleanUp()
        }
    }

    final class Counter: @unchecked Sendable {
        private(set) var count = 0
        func bump() {
            count += 1
        }
    }

    private func setUp(
        _ remote: [String: String] = ["a.md": "one\n"],
        inputs: GitHubMirrorModel.Inputs = .init()
    ) async throws -> Setup {
        let folder = try TempFolder("mirror-model")
        let home = try TempFolder("mirror-model-home")
        let github = FakeRepository(remote)
        let secrets = MemorySecretStore()
        var mirror = GitHubMirror(home: FenHome(root: home.root))
        mirror.remote = github
        mirror.secrets = secrets
        let id = UUID()
        let state = try await mirror.download(repo, token: nil, into: folder.root)
        try mirror.save(state, id: id)
        let reloads = Counter()
        let model = GitHubMirrorModel(
            mirror: mirror,
            id: id,
            inputs: inputs,
            root: { folder.root },
            changed: { reloads.bump() }
        )
        return Setup(folder: folder, home: home, github: github, secrets: secrets, model: model, reloads: reloads)
    }

    @Test func aWorkspaceWithNoSavedStateIsNotAMirror() throws {
        let home = try TempFolder("mirror-model-none")
        defer { home.cleanUp() }
        let model = GitHubMirrorModel(
            mirror: GitHubMirror(home: FenHome(root: home.root)),
            id: UUID(),
            root: { nil },
            changed: {}
        )
        #expect(!model.isMirror && model.repo == nil)
    }

    @Test func openPullsGitHubsChangesAndListsTheFolderAgain() async throws {
        let setup = try await setUp()
        defer { setup.cleanUp() }
        setup.github.edit("a.md", "two\n")
        await setup.model.open()
        #expect(try String(contentsOf: setup.folder.root.appendingPathComponent("a.md"), encoding: .utf8) == "two\n")
        #expect(setup.reloads.count == 1 && setup.model.message == nil && setup.model.working == nil)
    }

    @Test func backingUpWithoutATokenAsksForOneAndSendsNothing() async throws {
        let setup = try await setUp()
        defer { setup.cleanUp() }
        try setup.folder.write("new.md", "new\n")
        await setup.model.syncNow()
        #expect(setup.model.needsToken && setup.github.commits.isEmpty)
    }

    @Test func aSavedTokenLetsBackUpSendTheChangesAndTheStateSurvivesARestart() async throws {
        let setup = try await setUp()
        defer { setup.cleanUp() }
        #expect(!setup.model.saveToken("ghp_classic"))
        #expect(setup.model.saveToken("github_pat_fake123"))
        try setup.folder.write("new.md", "new\n")
        await setup.model.refreshPending()
        #expect(setup.model.pending == ["new.md"])
        await setup.model.syncNow()
        #expect(setup.github.text("new.md") == "new\n" && setup.model.pending.isEmpty)
        let reopened = GitHubMirrorModel(mirror: setup.model.mirror, id: setup.model.id, root: { nil }, changed: {})
        #expect(reopened.state?.commit == setup.model.state?.commit && reopened.state?.commit == "commit-2")
    }

    @Test func aConflictIsListedAndSavedAndStopsTheBackUpUntilYouChoose() async throws {
        let setup = try await setUp()
        defer { setup.cleanUp() }
        _ = setup.model.saveToken("github_pat_fake123")
        try setup.folder.write("a.md", "mine\n")
        setup.github.edit("a.md", "theirs\n")
        await setup.model.syncNow()
        #expect(setup.model.conflicts == ["a.md"] && setup.github.commits.isEmpty)
        #expect(setup.model.message?.contains("changed here and on GitHub") == true)
        let reopened = GitHubMirrorModel(mirror: setup.model.mirror, id: setup.model.id, root: { nil }, changed: {})
        #expect(reopened.conflicts == ["a.md"])
        await setup.model.resolve("a.md", keepMine: true)
        #expect(setup.model.conflicts.isEmpty)
        await setup.model.syncNow()
        #expect(setup.github.text("a.md") == "mine\n")
    }

    @Test func anAIChangeIsHeldBackFromBackUpUntilYouIncludeIt() async throws {
        let later = Date().addingTimeInterval(60)
        let setup = try await setUp(inputs: .init(aiChanges: { ["ai.md": later] }))
        defer { setup.cleanUp() }
        _ = setup.model.saveToken("github_pat_fake123")
        try setup.folder.write("ai.md", "from ai\n")
        try setup.folder.write("mine.md", "mine\n")
        await setup.model.refreshPending()
        #expect(setup.model.heldBack == ["ai.md"])
        await setup.model.syncNow()
        #expect(setup.github.text("mine.md") == "mine\n" && setup.github.text("ai.md") == nil)
        await setup.model.syncNow(includeAIChanges: true)
        #expect(setup.github.text("ai.md") == "from ai\n")
    }

    @Test func theSummaryCountsNotesAndPutsConflictsFirst() async throws {
        let later = Date().addingTimeInterval(60)
        let setup = try await setUp(inputs: .init(aiChanges: { ["ai.md": later] }))
        defer { setup.cleanUp() }
        #expect(setup.model.summary == "Backed up to octo/notes")
        try setup.folder.write("one.md", "1\n")
        try setup.folder.write("two.md", "2\n")
        try setup.folder.write("ai.md", "3\n")
        await setup.model.refreshPending()
        #expect(setup.model.summary == "2 notes not backed up · 1 AI change waits for you")
        _ = setup.model.saveToken("github_pat_fake123")
        try setup.folder.write("a.md", "mine\n")
        setup.github.edit("a.md", "theirs\n")
        await setup.model.syncNow()
        #expect(setup.model.summary == "1 note has a conflict to fix")
    }

    @Test func aTokenGitHubRefusesAsksForANewOne() async throws {
        let setup = try await setUp()
        defer { setup.cleanUp() }
        _ = setup.model.saveToken("github_pat_fake123")
        setup.github.failNext(with: GitSync.SyncError.authFailed(repo.title))
        await setup.model.pull()
        #expect(setup.model.needsToken && setup.model.message != nil)
    }
}
