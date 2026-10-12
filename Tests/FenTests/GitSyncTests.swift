@testable import FenCore
import Foundation
import Testing

struct GitHubRepoTests {
    @Test(arguments: [
        ("octo/notes", "octo", "notes"),
        ("https://github.com/octo/notes", "octo", "notes"),
        ("https://github.com/octo/notes.git", "octo", "notes"),
        ("https://github.com/octo/notes/", "octo", "notes"),
        ("git@github.com:octo/notes.git", "octo", "notes"),
        ("  octo/my.notes_2  ", "octo", "my.notes_2"),
    ])
    func parsesTheCommonForms(text: String, owner: String, name: String) {
        #expect(GitHubRepo.parse(text) == GitHubRepo(owner: owner, name: name))
    }

    @Test(arguments: [
        "", "octo", "octo/", "/notes", "a/b/c", "https://gitlab.com/octo/notes",
        "https://evil.com/github.com/octo/notes",
        "http://github.com/octo/notes", "octo/..", "octo/not es", "-octo/notes", "octo-/notes", "oc to/notes",
        "https://github.com/octo/notes/tree/main", "file:///tmp/notes", "octo/notes;rm",
    ])
    func refusesAnythingElse(text: String) {
        #expect(GitHubRepo.parse(text) == nil)
    }

    @Test func cloneURLIsAlwaysGitHubOverHTTPS() {
        #expect(GitHubRepo(owner: "octo", name: "notes").cloneURL.absoluteString == "https://github.com/octo/notes.git")
    }
}

struct GitHubTokenTests {
    @Test func acceptsScopedTokens() throws {
        #expect(try GitHubToken.validate("  github_pat_fake  ") == "github_pat_fake")
        #expect(try GitHubToken.validate("ghu_abc123") == "ghu_abc123")
        #expect(try GitHubToken.validate("ghs_abc123") == "ghs_abc123")
    }

    @Test func refusesBroadAndUnknownTokens() {
        #expect(throws: GitHubToken.Problem.classic) { try GitHubToken.validate("ghp_abc123") }
        #expect(throws: GitHubToken.Problem.classic) { try GitHubToken.validate("gho_abc123") }
        #expect(throws: GitHubToken.Problem.unknown) { try GitHubToken.validate("hunter2") }
        #expect(throws: GitHubToken.Problem.unknown) { try GitHubToken.validate("github_pat_abc def") }
        #expect(throws: GitHubToken.Problem.empty) { try GitHubToken.validate("   ") }
    }
}

struct GitSyncEnvironmentTests {
    private func header(_ env: [String: String]) -> String? {
        env.first { $0.key.hasPrefix("GIT_CONFIG_VALUE_") && $0.value.hasPrefix("Authorization") }?.value
    }

    @Test func tokenGoesOnlyToGitHubOverHTTPS() throws {
        let github = try #require(URL(string: "https://github.com/octo/notes.git"))
        #expect(header(GitSync.environment(for: github, token: "github_pat_x")) != nil)
        for other in [
            "http://github.com/octo/notes.git",
            "https://github.com.evil.com/octo/notes.git",
            "https://gitlab.com/octo/notes.git",
            "file:///tmp/remote.git",
        ] {
            #expect(
                try header(GitSync.environment(for: #require(URL(string: other)), token: "github_pat_x")) == nil,
                "\(other)"
            )
        }
        #expect(header(GitSync.environment(for: github, token: nil)) == nil)
        #expect(header(GitSync.environment(for: nil, token: "github_pat_x")) == nil)
    }

    @Test func storedLoginsAreNeverUsed() {
        let env = GitSync.environment(for: nil, token: nil)
        #expect(env["GIT_CONFIG_KEY_0"] == "credential.helper")
        #expect(env["GIT_CONFIG_VALUE_0"] == "")
    }

    @Test func gitReadsTheHeaderFromTheEnvironment() async throws {
        let folder = try TempFolder("sync-env")
        defer { folder.cleanUp() }
        let url = try #require(URL(string: "https://github.com/octo/notes.git"))
        let out = try await GitFixture.tool.run(
            ["config", "--get-urlmatch", "http.extraheader", url.absoluteString],
            in: folder.root,
            environment: GitSync.environment(for: url, token: "github_pat_secret")
        )
        let expected = Data("x-access-token:github_pat_secret".utf8).base64EncodedString()
        #expect(out.text == "Authorization: Basic \(expected)")
    }
}

struct GitSyncTests {
    @Test func cloneFillsAnEmptyFolderAndLeavesNoToken() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let root = try await fixture.clone("one", githubOrigin: true)
        #expect(try String(contentsOf: root.appendingPathComponent("notes/b.md"), encoding: .utf8) == "# B\n")
        let config = try String(contentsOf: root.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(!config.contains("extraheader"))
        #expect(!config.contains("x-access-token"))
        #expect(await fixture.sync.repo(at: root) == SyncFixture.repo)
    }

    @Test func cloneRefusesAFolderThatHasFiles() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.folder.folder("busy")
        try Data("mine".utf8).write(to: target.appendingPathComponent("keep.md"))
        await #expect(throws: GitSync.SyncError.folderNotEmpty) {
            try await fixture.sync.clone(fixture.remote, into: target, token: nil)
        }
        #expect(try String(contentsOf: target.appendingPathComponent("keep.md"), encoding: .utf8) == "mine")
    }

    @Test func aFailedCloneLeavesTheFolderEmpty() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.folder.folder("nothing")
        await #expect(throws: GitSync.SyncError.self) {
            try await fixture.sync.clone(
                fixture.folder.root.appendingPathComponent("missing.git"),
                into: target,
                token: nil
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func statusCountsAheadBehindAndChanges() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        let theirs = try await fixture.clone("theirs")
        #expect(try await fixture.sync.status(at: mine) == GitSync.Status(branch: "main", upstream: "origin/main"))
        try fixture.publish("c.md", "# C\n", from: theirs)
        try Data("# A2\n".utf8).write(to: mine.appendingPathComponent("a.md"))
        let status = try await fixture.sync.status(at: mine, fetch: true)
        #expect(status.behind == 1)
        #expect(status.changedFiles == 1)
        #expect(status.text == "main · 1 changed · 1 to pull")
    }

    // MARK: - Pull

    @Test func pullFastForwardsAndKeepsYourOtherEdits() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        let theirs = try await fixture.clone("theirs")
        try fixture.publish("c.md", "# C\n", from: theirs)
        try Data("# A edited\n".utf8).write(to: mine.appendingPathComponent("a.md"))
        #expect(try await fixture.sync.pull(at: mine) == .updated(commits: 1))
        #expect(try String(contentsOf: mine.appendingPathComponent("c.md"), encoding: .utf8) == "# C\n")
        #expect(try String(contentsOf: mine.appendingPathComponent("a.md"), encoding: .utf8) == "# A edited\n")
        #expect(try await fixture.sync.pull(at: mine) == .upToDate)
    }

    @Test func pullStopsWhenBothSidesHaveNewCommits() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        let theirs = try await fixture.clone("theirs")
        try fixture.publish("c.md", "# C\n", from: theirs)
        try Data("# mine\n".utf8).write(to: mine.appendingPathComponent("d.md"))
        try await fixture.sync.commitChanges(at: mine)
        #expect(try await fixture.sync.pull(at: mine) == .diverged)
        #expect(!FileManager.default.fileExists(atPath: mine.appendingPathComponent("c.md").path))
    }

    @Test func pullNeverOverwritesAnEditInTheWay() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        let theirs = try await fixture.clone("theirs")
        try fixture.publish("a.md", "# A from them\n", from: theirs)
        try Data("# A from me\n".utf8).write(to: mine.appendingPathComponent("a.md"))
        guard case .blocked = try await fixture.sync.pull(at: mine) else {
            Issue.record("Expected the pull to be blocked")
            return
        }
        #expect(try String(contentsOf: mine.appendingPathComponent("a.md"), encoding: .utf8) == "# A from me\n")
    }

    // MARK: - Commit and push

    @Test func aCommitHoldsOnlyTheChangedNotesAndNoFenFiles() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        try Data("# A\n\nOne more line.\n".utf8).write(to: mine.appendingPathComponent("a.md"))
        #expect(try await fixture.sync.commitChanges(at: mine) == 1)
        #expect(try fixture.git(mine, "show", "--stat", "--format=%s", "HEAD")
            .contains("1 file changed, 2 insertions(+)"))
        #expect(try fixture.git(mine, "log", "-1", "--format=%s") == "Update a.md")
        #expect(try fixture.git(mine, "status", "--porcelain").isEmpty)
        #expect(try fixture.git(mine, "ls-files").split(separator: "\n").sorted() == ["a.md", "notes/b.md"])
    }

    @Test func nothingChangedMakesNoCommit() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        #expect(try await fixture.sync.commitChanges(at: mine) == 0)
        #expect(try fixture.git(mine, "rev-list", "--count", "HEAD") == "1")
    }

    @Test func secretLookingFilesAreNeverCommitted() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        for name in [".env", "secrets.md", "deploy.pem", "id_ed25519"] {
            try Data("x".utf8).write(to: mine.appendingPathComponent(name))
        }
        try Data("# New\n".utf8).write(to: mine.appendingPathComponent("new.md"))
        #expect(try await fixture.sync.commitChanges(at: mine) == 1)
        #expect(try fixture.git(mine, "ls-files").split(separator: "\n").sorted() == ["a.md", "new.md", "notes/b.md"])
    }

    @Test func deletedAndNewFilesBothGoIn() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        try FileManager.default.removeItem(at: mine.appendingPathComponent("notes/b.md"))
        try Data("# N\n".utf8).write(to: mine.appendingPathComponent("n.md"))
        #expect(try await fixture.sync.commitChanges(at: mine) == 2)
        #expect(try fixture.git(mine, "log", "-1", "--format=%s") == "Update b.md, n.md")
    }

    @Test func pushSendsCommitsAndAnotherDeviceGetsThem() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        let theirs = try await fixture.clone("theirs")
        try Data("# A2\n".utf8).write(to: mine.appendingPathComponent("a.md"))
        try await fixture.sync.commitChanges(at: mine)
        #expect(try await fixture.sync.push(at: mine) == .pushed(commits: 1))
        #expect(try await fixture.sync.push(at: mine) == .nothingToPush)
        #expect(try await fixture.sync.pull(at: theirs) == .updated(commits: 1))
        #expect(try String(contentsOf: theirs.appendingPathComponent("a.md"), encoding: .utf8) == "# A2\n")
    }

    @Test func pushNeverForcesOverNewerRemoteWork() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        let theirs = try await fixture.clone("theirs")
        try fixture.publish("c.md", "# C\n", from: theirs)
        let remoteHead = try fixture.git(theirs, "rev-parse", "HEAD")
        try Data("# mine\n".utf8).write(to: mine.appendingPathComponent("d.md"))
        try await fixture.sync.commitChanges(at: mine)
        #expect(try await fixture.sync.push(at: mine) == .rejected)
        #expect(try fixture.git(fixture.remote, "rev-parse", "main") == remoteHead)
    }

    @Test func aFullCycleWithAGitHubOriginUsesTheStoredToken() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        try fixture.secrets.write("github_pat_abc", account: SyncFixture.repo.tokenAccount)
        let mine = try await fixture.clone("mine", githubOrigin: true)
        #expect(fixture.sync.token(for: SyncFixture.repo) == "github_pat_abc")
        try Data("# A2\n".utf8).write(to: mine.appendingPathComponent("a.md"))
        try await fixture.sync.commitChanges(at: mine)
        #expect(try await fixture.sync.push(at: mine) == .pushed(commits: 1))
        let config = try String(contentsOf: mine.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(!config.contains("github_pat_abc"))
        #expect(try await fixture.sync.status(at: mine, fetch: true).isClean)
    }

    @Test func aFolderThatIsNotARepositoryIsReported() async throws {
        let folder = try TempFolder("sync-none")
        defer { folder.cleanUp() }
        let sync = GitSync(git: GitFixture.tool, secrets: MemorySecretStore())
        await #expect(throws: GitSync.SyncError.notARepository) { try await sync.status(at: folder.root) }
    }
}
