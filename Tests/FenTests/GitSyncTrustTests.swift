@testable import FenCore
import Foundation
import Testing

/// Which folders Fen syncs with your token (`GitSync+Trust.swift`), and what a refused push or a failed
/// fetch tells you.
@MainActor
struct GitSyncTrustTests {
    /// A folder whose own git settings run a program on fetch: an ssh origin on GitHub and
    /// `core.sshCommand`. The program writes its environment to `dump`.
    private func hostile(_ fixture: SyncFixture) async throws -> (root: URL, dump: URL) {
        let root = try await fixture.clone("hostile")
        let dump = fixture.folder.root.appendingPathComponent("env.txt")
        let script = fixture.folder.root.appendingPathComponent("ssh.sh")
        try Data("#!/bin/sh\nenv > '\(dump.path)'\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try fixture.git(root, "remote", "set-url", "origin", "git@github.com:octo/notes.git")
        try fixture.git(root, "config", "core.sshCommand", script.path)
        try fixture.secrets.write("github_pat_secret", account: SyncFixture.repo.tokenAccount)
        return (root, dump)
    }

    @Test func aFolderWhoseSettingsRunAProgramIsNotSynced() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let (root, dump) = try await hostile(fixture)
        let model = GitHubSyncModel(sync: fixture.sync, api: FakeGitHub(), root: { root }, changed: {})
        await model.open()
        await model.pull()
        await model.syncNow()
        #expect(model.repo == nil)
        #expect(model.refusal?.contains("core.sshcommand") == true)
        #expect(model.message == model.refusal)
        let seen = (try? String(contentsOf: dump, encoding: .utf8)) ?? ""
        #expect(!seen.contains("Authorization"))
    }

    @Test func gitSyncNeverHandsSuchAFolderTheToken() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let (root, dump) = try await hostile(fixture)
        #expect(await fixture.sync.environment(at: root)["GIT_CONFIG_COUNT"] == "1")
        _ = try? await fixture.sync.status(at: root, fetch: true)
        let seen = try String(contentsOf: dump, encoding: .utf8)
        #expect(seen.contains("GIT_CONFIG_VALUE_0"))
        #expect(!seen.contains("Authorization"))
    }

    @Test func aPlainRepositoryWithAGitHubOriginGetsTheToken() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let root = try await fixture.clone("plain")
        try fixture.git(root, "remote", "set-url", "origin", SyncFixture.repo.cloneURL.absoluteString)
        try fixture.git(root, "config", "pull.rebase", "false")
        try fixture.git(root, "config", "user.name", "Me")
        try fixture.secrets.write("github_pat_secret", account: SyncFixture.repo.tokenAccount)
        #expect(await fixture.sync.refusal(at: root) == nil)
        let env = await fixture.sync.environment(at: root)
        #expect(env.values.contains { $0.hasPrefix("Authorization: Basic") })
    }

    @Test func aFenCloneSkipsTheSettingsCheck() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        // The fixture's `url.*.insteadOf` would send the token elsewhere in a folder Fen didn't make.
        let root = try await fixture.clone("mine", githubOrigin: true)
        var sync = fixture.sync
        #expect(await sync.refusal(at: root)?.contains("insteadof") == true)
        sync.clonedByFen = true
        #expect(await sync.refusal(at: root) == nil)
    }

    @Test func onlySettingsThatNameThingsAreSafe() {
        let safe = [
            "core.repositoryformatversion", "core.bare", "core.logallrefupdates", "remote.origin.url",
            "remote.origin.fetch", "branch.main.remote", "branch.main.merge", "user.name", "pull.rebase",
        ]
        #expect(GitSync.unsafeConfigKeys(safe).isEmpty)
        for key in [
            "filter.lfs.clean", "core.sshCommand", "core.fsmonitor", "core.hooksPath", "core.pager", "core.askpass",
            "include.path", "includeIf.gitdir:/x/.path", "credential.helper", "url./tmp/x.insteadOf", "http.proxy",
            "http.https://github.com/.extraheader", "remote.origin.uploadpack", "remote.origin.receivepack",
            "remote.origin.proxy", "diff.x.textconv", "protocol.allow", "remote.url", "odd",
        ] {
            #expect(GitSync.unsafeConfigKeys([key]) == [key], "\(key)")
        }
    }

    @Test func aWorkspaceInsideARepositoryIsRefused() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine", githubOrigin: true)
        try fixture.secrets.write("github_pat_fake", account: SyncFixture.repo.tokenAccount)
        let sub = mine.appendingPathComponent("notes")
        let before = try fixture.git(fixture.remote, "rev-parse", "main")
        let model = GitHubSyncModel(
            sync: fixture.sync,
            api: FakeGitHub(),
            inputs: GitHubSyncModel.Inputs(clonedByFen: { true }),
            root: { sub },
            changed: {}
        )
        await model.open()
        #expect(model.repo == nil)
        #expect(model.refusal?.contains("top of the git repository") == true)
        try Data("# B2\n".utf8).write(to: sub.appendingPathComponent("b.md"))
        await model.syncNow()
        #expect(model.message == model.refusal)
        #expect(try fixture.git(fixture.remote, "rev-parse", "main") == before)
    }

    @Test func aPushTheRemoteTurnsDownForItsOwnReasonSaysWhy() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        // A non-bare remote with `main` checked out refuses the push without any hook.
        let live = try await fixture.clone("live")
        let mine = try await fixture.clone("mine")
        try fixture.git(mine, "remote", "set-url", "origin", live.path)
        try Data("# mine\n".utf8).write(to: mine.appendingPathComponent("d.md"))
        try await fixture.sync.commitChanges(at: mine)
        do {
            let result = try await fixture.sync.push(at: mine)
            Issue.record("The push wasn't refused: \(result)")
        } catch let GitSync.SyncError.pushRefused(reason) {
            #expect(reason.contains("checked out"))
        }
    }

    @Test func fetchAndPushErrorsNeverShowTheToken() async throws {
        let fixture = try SyncFixture()
        defer { fixture.cleanUp() }
        let mine = try await fixture.clone("mine")
        try fixture.git(mine, "remote", "set-url", "origin", SyncFixture.repo.cloneURL.absoluteString)
        // git names the rewritten address, token and all, in its error.
        try fixture.git(mine, "config", "url./nonexistent/github_pat_leak123/.insteadOf", "https://github.com/")
        try fixture.secrets.write("github_pat_leak123", account: SyncFixture.repo.tokenAccount)
        do {
            _ = try await fixture.sync.status(at: mine, fetch: true)
            Issue.record("The fetch didn't fail.")
        } catch {
            #expect(!error.localizedDescription.contains("github_pat_leak123"))
            #expect(error.localizedDescription.contains("***"))
        }
        try Data("# mine\n".utf8).write(to: mine.appendingPathComponent("d.md"))
        try await fixture.sync.commitChanges(at: mine)
        do {
            let result = try await fixture.sync.push(at: mine)
            Issue.record("The push didn't fail: \(result)")
        } catch {
            #expect(!error.localizedDescription.contains("github_pat_leak123"))
            #expect(error.localizedDescription.contains("***"))
        }
    }

    @Test func backUpKeepsAReviewBranchWithCommitsGitHubDoesNotHave() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let branch = "fen/changes-20260101-000000"
        try setup.git("switch", "-q", "-c", branch)
        try setup.edit("a.md", "# A, on the review branch\n")
        try setup.git("add", "-A")
        try setup.git("commit", "-q", "-m", "review edit")
        let before = try setup.remoteGit("rev-parse", "main")
        let model = setup.model()
        await model.syncNow()
        #expect(try setup.git("rev-parse", "--abbrev-ref", "HEAD") == branch)
        #expect(model.message?.contains("review branch") == true)
        let text = try String(contentsOf: setup.mine.appendingPathComponent("a.md"), encoding: .utf8)
        #expect(text == "# A, on the review branch\n")
        #expect(try setup.remoteGit("rev-parse", "main") == before)
    }
}
