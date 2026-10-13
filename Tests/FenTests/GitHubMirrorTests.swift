@testable import FenCore
import Foundation
import Testing

struct GitHubMirrorTests {
    private let repo = GitHubRepo(owner: "octo", name: "notes")

    private struct Setup {
        let folder: TempFolder
        let home: TempFolder
        let github: FakeRepository
        let mirror: GitHubMirror
        var state: MirrorState

        func cleanUp() {
            folder.cleanUp()
            home.cleanUp()
        }

        func read(_ path: String) -> String? {
            try? String(contentsOf: folder.root.appendingPathComponent(path), encoding: .utf8)
        }
    }

    private func setUp(_ remote: [String: String]) async throws -> Setup {
        let folder = try TempFolder("mirror")
        let home = try TempFolder("mirror-home")
        let github = FakeRepository(remote)
        var mirror = GitHubMirror(home: FenHome(root: home.root))
        mirror.remote = github
        let state = try await mirror.download(repo, token: nil, into: folder.root)
        return Setup(folder: folder, home: home, github: github, mirror: mirror, state: state)
    }

    // MARK: - Clone

    @Test
    func gitsHashOfAFileMatchesGit() {
        // `printf 'hello\n' | git hash-object --stdin`
        #expect(GitHubMirror.blobSHA(of: Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(GitHubMirror.blobSHA(of: Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test
    func cloneCopiesNotesAndLeavesOutGitSecretsAndHugeFiles() async throws {
        let big = String(repeating: "a", count: GitHubMirror.maxFileSize + 1)
        let setup = try await setUp([
            "a.md": "# A\n", "docs/b.md": "# B\n", ".git/config": "x", ".env": "KEY=1", "key.pem": "x", "big.md": big,
            ".fen/schema.yaml": "types: []\n",
        ])
        defer { setup.cleanUp() }
        #expect(setup.read("a.md") == "# A\n")
        #expect(setup.read("docs/b.md") == "# B\n")
        #expect(setup.read(".fen/schema.yaml") == "types: []\n")
        #expect(setup.read(".git/config") == nil && setup.read(".env") == nil)
        #expect(setup.read("key.pem") == nil && setup.read("big.md") == nil)
        #expect(Set(setup.state.files.keys) == ["a.md", "docs/b.md", ".fen/schema.yaml"])
        #expect(setup.state.commit == "commit-1" && setup.state.branch == "main")
        // Nothing but the notes is in the folder.
        let names = try FileManager.default.subpathsOfDirectory(atPath: setup.folder.root.path)
        #expect(!names.contains { $0.contains("github-mirror") })
    }

    @Test
    func stateIsSavedOutsideTheFolderAndReadBack() async throws {
        let setup = try await setUp(["a.md": "# A\n"])
        defer { setup.cleanUp() }
        let id = UUID()
        // The file keeps whole seconds, so compare with a date that has none left over.
        var state = setup.state
        state.syncedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try setup.mirror.save(state, id: id)
        #expect(setup.mirror.load(id: id) == state)
        #expect(setup.mirror.load(id: UUID()) == nil)
    }

    // MARK: - Pull

    @Test
    func pullTakesGitHubsChangesToNotesYouDidNotTouch() async throws {
        let setup = try await setUp(["a.md": "one\n", "b.md": "two\n", "c.md": "three\n"])
        defer { setup.cleanUp() }
        setup.github.edit("a.md", "one, edited\n")
        setup.github.edit("b.md", nil)
        setup.github.edit("new/d.md", "four\n")
        let (state, report) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        #expect(setup.read("a.md") == "one, edited\n")
        #expect(setup.read("b.md") == nil)
        #expect(setup.read("new/d.md") == "four\n")
        #expect(setup.read("c.md") == "three\n")
        #expect(report.updated == 3)
        #expect(state.conflicts.isEmpty)
        #expect(setup.mirror.pendingChanges(state, root: setup.folder.root).isEmpty)
    }

    @Test
    func pullDoesNothingWhenGitHubHasNoNewCommit() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        let (state, report) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        #expect(state == setup.state && report.updated == 0)
    }

    @Test
    func aNoteYouEditedIsNeverOverwrittenAndBecomesAConflictWhenGitHubChangedItToo() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "mine\n")
        setup.github.edit("a.md", "theirs\n")
        let (state, _) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        #expect(setup.read("a.md") == "mine\n")
        #expect(Array(state.conflicts.keys) == ["a.md"])
        // Base stays, so nothing is lost and a second pull gives the same answer.
        #expect(state.files["a.md"] == setup.state.files["a.md"])
    }

    @Test
    func aNoteYouEditedStaysWhenGitHubDeletedIt() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "mine\n")
        setup.github.edit("a.md", nil)
        let (state, _) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        #expect(setup.read("a.md") == "mine\n")
        #expect(state.conflicts["a.md"]?.isEmpty == true)
    }

    @Test
    func theSameEditOnBothSidesIsNotAConflict() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "same\n")
        setup.github.edit("a.md", "same\n")
        let (state, report) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        #expect(state.conflicts.isEmpty && report.updated == 0)
        #expect(state.files["a.md"] == GitHubMirror.blobSHA(of: Data("same\n".utf8)))
    }

    @Test
    func aNewNoteOnBothSidesWithDifferentTextIsAConflict() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("new.md", "mine\n")
        setup.github.edit("new.md", "theirs\n")
        let (state, _) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        #expect(setup.read("new.md") == "mine\n")
        #expect(Array(state.conflicts.keys) == ["new.md"])
    }

    // MARK: - Push

    @Test
    func pushSendsAddedChangedAndDeletedNotesInOneCommit() async throws {
        let setup = try await setUp(["a.md": "one\n", "b.md": "two\n", "c.md": "three\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "one, edited\n")
        try setup.folder.write("sub/new.md", "new\n")
        try FileManager.default.removeItem(at: setup.folder.root.appendingPathComponent("b.md"))
        let (state, sent) = try await setup.mirror.push(setup.state, root: setup.folder.root, token: "github_pat_x")
        #expect(sent == 3)
        #expect(setup.github.commits.count == 1)
        #expect(setup.github.text("a.md") == "one, edited\n")
        #expect(setup.github.text("sub/new.md") == "new\n")
        #expect(setup.github.text("b.md") == nil && setup.github.text("c.md") == "three\n")
        #expect(setup.github.messages.count == 1 && !setup.github.messages[0].isEmpty)
        #expect(state.commit == "commit-2")
        let again = try await setup.mirror.push(state, root: setup.folder.root, token: "github_pat_x")
        #expect(again.1 == 0 && setup.github.commits.count == 1)
    }

    @Test
    func pushLeavesOutHeldNotesSecretsAndHugeFiles() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("held.md", "ai\n")
        try setup.folder.write("ok.md", "ok\n")
        try setup.folder.write(".env", "KEY=1\n")
        try setup.folder.write("big.md", String(repeating: "a", count: GitHubMirror.maxFileSize + 1))
        let (_, sent) = try await setup.mirror.push(
            setup.state,
            root: setup.folder.root,
            token: "github_pat_x",
            held: ["held.md"]
        )
        #expect(sent == 1)
        #expect(setup.github.text("ok.md") == "ok\n")
        #expect(setup.github.text("held.md") == nil && setup.github.text(".env") == nil && setup.github
            .text("big.md") == nil)
    }

    @Test
    func aNoteThatGrewPastTheLimitIsNeitherSentNorDeleted() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", String(repeating: "a", count: GitHubMirror.maxFileSize + 1))
        let (_, sent) = try await setup.mirror.push(setup.state, root: setup.folder.root, token: "github_pat_x")
        #expect(sent == 0 && setup.github.text("a.md") == "one\n")
        #expect(setup.mirror.pendingChanges(setup.state, root: setup.folder.root).isEmpty)
    }

    @Test
    func pushPullsFirstSoGitHubsOtherChangesComeInAndYoursGoOut() async throws {
        let setup = try await setUp(["a.md": "one\n", "b.md": "two\n"])
        defer { setup.cleanUp() }
        setup.github.edit("b.md", "two, from GitHub\n")
        try setup.folder.write("a.md", "one, from here\n")
        let (_, sent) = try await setup.mirror.push(setup.state, root: setup.folder.root, token: "github_pat_x")
        #expect(sent == 1)
        #expect(setup.read("b.md") == "two, from GitHub\n")
        #expect(setup.github.text("a.md") == "one, from here\n")
        #expect(setup.github.text("b.md") == "two, from GitHub\n")
    }

    @Test
    func ifTheBranchMovesWhileSendingPushPullsAndTriesAgain() async throws {
        let setup = try await setUp(["a.md": "one\n", "b.md": "two\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "one, from here\n")
        setup.github.beforeNextCommit = { setup.github.edit("b.md", "two, moved\n") }
        let (state, sent) = try await setup.mirror.push(setup.state, root: setup.folder.root, token: "github_pat_x")
        #expect(sent == 1 && setup.github.commits.count == 1)
        #expect(setup.github.text("a.md") == "one, from here\n" && setup.github.text("b.md") == "two, moved\n")
        #expect(setup.read("b.md") == "two, moved\n")
        #expect(state.commit == "commit-3")
    }

    @Test
    func pushStopsWhileANoteIsInConflict() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "mine\n")
        try setup.folder.write("other.md", "other\n")
        setup.github.edit("a.md", "theirs\n")
        await #expect(throws: MirrorError.conflicts(1)) {
            _ = try await setup.mirror.push(setup.state, root: setup.folder.root, token: "github_pat_x")
        }
        #expect(setup.github.commits.isEmpty)
        #expect(setup.read("a.md") == "mine\n")
    }

    // MARK: - Conflicts

    @Test
    func keepingMineSendsMyNoteOnTheNextPush() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "mine\n")
        setup.github.edit("a.md", "theirs\n")
        var (state, _) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        state = try await setup.mirror.resolve("a.md", keepMine: true, in: state, root: setup.folder.root, token: nil)
        #expect(state.conflicts.isEmpty && setup.read("a.md") == "mine\n")
        let sent = try await setup.mirror.push(state, root: setup.folder.root, token: "github_pat_x")
        #expect(sent.1 == 1 && setup.github.text("a.md") == "mine\n")
    }

    @Test
    func usingGitHubsReplacesMyNote() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "mine\n")
        setup.github.edit("a.md", "theirs\n")
        var (state, _) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        state = try await setup.mirror.resolve("a.md", keepMine: false, in: state, root: setup.folder.root, token: nil)
        #expect(state.conflicts.isEmpty && setup.read("a.md") == "theirs\n")
        #expect(setup.mirror.pendingChanges(state, root: setup.folder.root).isEmpty)
    }

    @Test
    func usingGitHubsDeletionRemovesMyNoteAndKeepingMineSendsItAgain() async throws {
        let setup = try await setUp(["a.md": "one\n", "b.md": "two\n"])
        defer { setup.cleanUp() }
        try setup.folder.write("a.md", "mine\n")
        try setup.folder.write("b.md", "mine too\n")
        setup.github.edit("a.md", nil)
        setup.github.edit("b.md", nil)
        var (state, _) = try await setup.mirror.pull(setup.state, root: setup.folder.root, token: nil)
        state = try await setup.mirror.resolve("a.md", keepMine: false, in: state, root: setup.folder.root, token: nil)
        state = try await setup.mirror.resolve("b.md", keepMine: true, in: state, root: setup.folder.root, token: nil)
        #expect(setup.read("a.md") == nil && setup.read("b.md") == "mine too\n")
        let sent = try await setup.mirror.push(state, root: setup.folder.root, token: "github_pat_x")
        #expect(sent.1 == 1 && setup.github.text("b.md") == "mine too\n")
    }

    // MARK: - Safety

    @Test
    func aPathThatLeavesTheFolderIsRefusedAndNothingIsWritten() async throws {
        let folder = try TempFolder("mirror-escape")
        let home = try TempFolder("mirror-escape-home")
        defer {
            folder.cleanUp()
            home.cleanUp()
        }
        let outside = folder.root.deletingLastPathComponent().appendingPathComponent("evil-\(UUID().uuidString).md")
        for bad in ["../" + outside.lastPathComponent, "a/../../" + outside.lastPathComponent, "/abs.md"] {
            let github = FakeRepository(["ok.md": "ok\n", bad: "evil\n"])
            var mirror = GitHubMirror(home: FenHome(root: home.root))
            mirror.remote = github
            let target = folder.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            await #expect(throws: MirrorError.unsafePath(bad)) {
                _ = try await mirror.download(repo, token: nil, into: target)
            }
            #expect(!FileManager.default.fileExists(atPath: outside.path))
            #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("ok.md").path))
        }
    }

    @Test
    func aSymlinkInTheFolderIsNotFollowedOrSent() async throws {
        let setup = try await setUp(["a.md": "one\n"])
        defer { setup.cleanUp() }
        let secret = try TempFolder("mirror-outside")
        defer { secret.cleanUp() }
        try secret.write("private.md", "private\n")
        try FileManager.default.createSymbolicLink(
            at: setup.folder.root.appendingPathComponent("link.md"),
            withDestinationURL: secret.root.appendingPathComponent("private.md")
        )
        try FileManager.default.createSymbolicLink(
            at: setup.folder.root.appendingPathComponent("linked"),
            withDestinationURL: secret.root
        )
        let (_, sent) = try await setup.mirror.push(setup.state, root: setup.folder.root, token: "github_pat_x")
        #expect(sent == 0 && setup.github.commits.isEmpty)
    }
}
