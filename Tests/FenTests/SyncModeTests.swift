@testable import FenCore
import Foundation
import Testing

/// A stand-in for the GitHub REST API: pull requests by head branch.
final class FakeGitHub: GitHubAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var pulls: [String: PullRequest] = [:]
    private(set) var opened: [(head: String, base: String, title: String)] = []

    func pullRequest(head branch: String, in _: GitHubRepo, token _: String?) async throws -> PullRequest? {
        lock.withLock { pulls[branch] }
    }

    func openPullRequest(
        head: String,
        base: String,
        title: String,
        body _: String,
        in repo: GitHubRepo,
        token _: String
    ) async throws -> PullRequest {
        lock.withLock {
            let pull = PullRequest(
                number: opened.count + 1,
                url: URL(string: "https://github.com/\(repo.title)/pull/\(opened.count + 1)")!,
                state: .open
            )
            pulls[head] = pull
            opened.append((head, base, title))
            return pull
        }
    }

    func finish(_ branch: String, as state: PullRequest.State) {
        lock.withLock { pulls[branch]?.state = state }
    }

    func setConflicts(_ branch: String, _ value: Bool?) {
        lock.withLock { pulls[branch]?.hasConflicts = value }
    }
}

/// What a workspace's settings and activity say, changeable while a test runs.
@MainActor
final class SyncKnobs {
    var mode: SyncMode? = .directCommit
    var pushesAIChanges = false
    var aiChanges: [String: Date] = [:]
    /// The fixture points `origin` at a local folder with `url.*.insteadOf`, which only a Fen clone may have.
    var clonedByFen = true
}

@MainActor
struct SyncModeSetup {
    let fixture: SyncFixture
    let mine: URL
    let api = FakeGitHub()
    let knobs = SyncKnobs()

    init(fixture given: SyncFixture? = nil, token: Bool = true) async throws {
        let fixture = try given ?? SyncFixture()
        self.fixture = fixture
        mine = try await fixture.clone("mine", githubOrigin: true)
        if token {
            try fixture.secrets.write("github_pat_fake", account: SyncFixture.repo.tokenAccount)
        }
    }

    func model(saveDelay: Duration = .seconds(60)) -> GitHubSyncModel {
        let knobs = knobs
        let root = mine
        return GitHubSyncModel(
            sync: fixture.sync,
            api: api,
            inputs: GitHubSyncModel.Inputs(
                mode: { knobs.mode },
                pushesAIChanges: { knobs.pushesAIChanges },
                aiChanges: { knobs.aiChanges },
                clonedByFen: { knobs.clonedByFen },
                saveDelay: saveDelay
            ),
            root: { root },
            changed: {}
        )
    }

    func edit(_ path: String, _ text: String) throws {
        let url = mine.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try fixture.git(mine, arguments)
    }

    func remoteGit(_ arguments: String...) throws -> String {
        try fixture.git(fixture.remote, arguments)
    }

    /// The `fen/changes-*` branches on the remote.
    func remoteReviewBranches() throws -> [String] {
        try remoteGit("branch", "--list", "fen/changes-*").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func cleanUp() {
        fixture.cleanUp()
    }
}

extension SyncFixture {
    @discardableResult
    func git(_ directory: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Other", "-c", "user.email=o@example.com", "-c", "commit.gpgsign=false"]
            + arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "HOME": folder.root.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
struct DirectCommitTests {
    @Test func backUpCommitsAndPushesToTheDefaultBranchWithNoBranchOrPullRequest() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(model.message == nil)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A2")
        #expect(try setup.remoteReviewBranches().isEmpty)
        #expect(setup.api.opened.isEmpty)
        #expect(model.pullRequest == nil)
        #expect(try setup.git("branch", "--show-current") == "main")
    }

    @Test func theHeaderUsesBackupWordsOnly() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let model = setup.model()
        await model.open()
        let clean = SyncSummary.text(mode: .directCommit, status: model.status, pullRequest: nil, held: 0, repo: "o/n")
        #expect(clean == "Backed up")
        try setup.edit("a.md", "# A2\n")
        await model.refresh(fetch: false)
        let dirty = SyncSummary.text(mode: .directCommit, status: model.status, pullRequest: nil, held: 0, repo: "o/n")
        #expect(dirty == "1 note not backed up")
        for word in ["branch", "pull", "PR", "commit", "push", "main"] {
            #expect(!clean.contains(word) && !dirty.contains(word))
        }
    }

    @Test func aiChangedNotesStayOutOfTheBackupUntilYouOptIn() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        try setup.edit("a.md", "# A, changed by AI\n")
        try setup.edit("notes/b.md", "# B, changed by me\n")
        setup.knobs.aiChanges = ["a.md": Date().addingTimeInterval(5)]
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(try setup.remoteGit("show", "main:notes/b.md") == "# B, changed by me")
        #expect(try setup.remoteGit("show", "main:a.md") == "# A")
        #expect(model.heldBack == ["a.md"])
        #expect(try setup.git("status", "--porcelain") == "M a.md")
        #expect(try setup.remoteReviewBranches().isEmpty)

        setup.knobs.pushesAIChanges = true
        await model.syncNow()
        #expect(try setup.remoteGit("show", "main:a.md") == "# A, changed by AI")
        #expect(model.heldBack.isEmpty)
    }

    @Test func youCanBackUpAiChangesOnce() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        try setup.edit("a.md", "# A, changed by AI\n")
        setup.knobs.aiChanges = ["a.md": Date().addingTimeInterval(5)]
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(try setup.remoteGit("show", "main:a.md") == "# A")
        await model.syncNow(includeAIChanges: true)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A, changed by AI")
    }

    @Test func anAiChangeThatWasCommittedBeforeIsNotHeldAgain() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        // The AI change is older than the last commit of the note, so it was already backed up.
        setup.knobs.aiChanges = ["a.md": Date(timeIntervalSince1970: 1000)]
        try setup.edit("a.md", "# A, then edited by me\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(try setup.remoteGit("show", "main:a.md") == "# A, then edited by me")
        #expect(model.heldBack.isEmpty)
    }

    @Test func aStagedHeldNoteIsStillLeftOut() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        try setup.edit("a.md", "# A, changed by AI\n")
        try setup.git("add", "a.md")
        try setup.edit("notes/b.md", "# B2\n")
        setup.knobs.aiChanges = ["a.md": Date().addingTimeInterval(5)]
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(try setup.remoteGit("show", "main:a.md") == "# A")
        #expect(try setup.remoteGit("show", "main:notes/b.md") == "# B2")
    }

    @Test func aChangeMadeThroughTheWriteGateIsHeldBack() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let home = try TempHome()
        defer { home.cleanUp() }
        let id = UUID()
        let root = setup.mine
        let workspace = Workspace(id: id, name: "W", path: root.path, settings: WorkspaceSettings())
        let gate = WriteGate(home: home.home, workspaces: { [workspace] }, rootURL: { _ in root })
        let change = try ProposedChange(
            workspaceID: id,
            operation: "enrich",
            edit: .append(path: "a.md", text: "From AI.\n"),
            scope: ["a.md"],
            baseHash: gate.contentHash(workspaceID: id, relativePath: "a.md"),
            invokedByUser: true,
            provenance: Provenance(provider: "Ollama", model: "llama3")
        )
        _ = try gate.submit(change)
        try setup.edit("notes/b.md", "# B by me\n")
        let knobs = setup.knobs
        knobs.aiChanges = AIChangedPaths.latest(in: gate.entries(for: id))
        #expect(knobs.aiChanges.keys.sorted() == ["a.md"])

        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(try setup.remoteGit("show", "main:a.md") == "# A")
        #expect(try setup.remoteGit("show", "main:notes/b.md") == "# B by me")
    }
}

struct AIChangedPathsTests {
    private func entry(
        _ path: String,
        toPath: String? = nil,
        at seconds: TimeInterval,
        branch: String? = nil,
        undone: Bool = false
    ) -> ActivityEntry {
        ActivityEntry(
            id: UUID(),
            runID: UUID(),
            workspaceID: UUID(),
            date: Date(timeIntervalSince1970: seconds),
            operation: "enrich",
            edit: "append",
            tier: .additive,
            path: path,
            toPath: toPath,
            provenance: Provenance(provider: "p", model: "m"),
            approvedBy: .user,
            diff: LineDiff(lines: [], added: 0, removed: 0, oldLineCount: 0),
            undoneAt: undone ? Date() : nil,
            branch: branch
        )
    }

    @Test func onlyAppliedInPlaceChangesCount() {
        let found = AIChangedPaths.latest(in: [
            entry("a.md", at: 10),
            entry("a.md", at: 20),
            entry("undone.md", at: 30, undone: true),
            entry("branched.md", at: 40, branch: "fen/claude"),
            entry("old.md", toPath: "new.md", at: 50),
        ])
        #expect(found == [
            "a.md": Date(timeIntervalSince1970: 20),
            "old.md": Date(timeIntervalSince1970: 50),
            "new.md": Date(timeIntervalSince1970: 50),
        ])
    }
}
