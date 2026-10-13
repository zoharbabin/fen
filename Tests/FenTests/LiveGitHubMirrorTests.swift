@testable import FenCore
import Foundation
import Testing

/// The iOS copy of a GitHub repository, against a real throwaway repository (issues #60, #62). It talks to
/// GitHub through `GitHubREST` only, so it needs no git. It adds one note, then removes it, and leaves the
/// repository as it found it. The token never goes in an environment variable or a tracked file: keep it
/// in a file only you can read.
///
///     chmod 600 ~/.fen-live-github-token
///     FEN_LIVE_GITHUB_REPO=zoharbabin/fen-sync-test FEN_LIVE_GITHUB_TOKEN_FILE=~/.fen-live-github-token \
///         swift test --no-parallel --filter LiveGitHubMirror
@Suite(
    "Live GitHub mirror (issues #60, #62)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["FEN_LIVE_GITHUB_REPO"] != nil)
)
struct LiveGitHubMirrorTests {
    private func credentials() throws -> (repo: GitHubRepo, token: String) {
        let env = ProcessInfo.processInfo.environment
        let slug = try #require(env["FEN_LIVE_GITHUB_REPO"])
        let repo = try #require(GitHubRepo.parse(slug))
        let path = try #require(env["FEN_LIVE_GITHUB_TOKEN_FILE"]) as NSString
        let url = URL(fileURLWithPath: path.expandingTildeInPath)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        try #require(mode == 0o600, "Run chmod 600 on the token file.")
        let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return (repo, token)
    }

    private func makeMirror() throws -> (GitHubMirror, TempHome) {
        let home = try TempHome()
        var mirror = GitHubMirror(home: home.home)
        mirror.secrets = MemorySecretStore()
        return (mirror, home)
    }

    @Test("a real repository copies down, takes an edit, pulls, and holds a conflict until you choose")
    func roundTrip() async throws {
        let (repo, token) = try credentials()
        let (mirror, homeA) = try makeMirror()
        let (_, homeB) = try makeMirror()
        let folderA = try TempFolder("live-mirror-a")
        let folderB = try TempFolder("live-mirror-b")
        defer {
            homeA.cleanUp()
            homeB.cleanUp()
            folderA.cleanUp()
            folderB.cleanUp()
        }
        let name = "fen-live-\(UUID().uuidString.prefix(8)).md"
        let fileA = folderA.root.appendingPathComponent(name)
        let fileB = folderB.root.appendingPathComponent(name)

        // A wrong token fails.
        await #expect(throws: (any Error).self) {
            _ = try await mirror.download(
                repo,
                token: "github_pat_" + String(repeating: "x", count: 40),
                into: folderB.root
            )
        }

        // Copy down, add a note, send it.
        var stateA = try await mirror.download(repo, token: token, into: folderA.root)
        #expect(mirror.pendingChanges(stateA, root: folderA.root).isEmpty)
        try "# Live\n\nFirst line.\n".write(to: fileA, atomically: true, encoding: .utf8)
        #expect(mirror.pendingChanges(stateA, root: folderA.root) == [name])
        var sent: Int
        (stateA, sent) = try await mirror.push(stateA, root: folderA.root, token: token)
        #expect(sent == 1)
        #expect(mirror.pendingChanges(stateA, root: folderA.root).isEmpty)

        // A second copy sees the note.
        var stateB = try await mirror.download(repo, token: token, into: folderB.root)
        #expect(try String(contentsOf: fileB, encoding: .utf8) == "# Live\n\nFirst line.\n")

        // A change on GitHub reaches a copy that has no edits.
        try "# Live\n\nFrom A.\n".write(to: fileA, atomically: true, encoding: .utf8)
        (stateA, sent) = try await mirror.push(stateA, root: folderA.root, token: token)
        #expect(sent == 1)
        let report: PullReport
        (stateB, report) = try await mirror.pull(stateB, root: folderB.root, token: token)
        #expect(report.updated == 1)
        #expect(try String(contentsOf: fileB, encoding: .utf8) == "# Live\n\nFrom A.\n")

        // Both sides edit the same note. The pull holds it as a conflict and writes nothing into it.
        try "# Live\n\nA again.\n".write(to: fileA, atomically: true, encoding: .utf8)
        (stateA, sent) = try await mirror.push(stateA, root: folderA.root, token: token)
        #expect(sent == 1)
        try "# Live\n\nFrom B.\n".write(to: fileB, atomically: true, encoding: .utf8)
        (stateB, _) = try await mirror.pull(stateB, root: folderB.root, token: token)
        #expect(stateB.conflicts.keys.sorted() == [name])
        #expect(try String(contentsOf: fileB, encoding: .utf8) == "# Live\n\nFrom B.\n")
        await #expect(throws: MirrorError.conflicts(1)) {
            _ = try await mirror.push(stateB, root: folderB.root, token: token)
        }

        // Keep Mine sends B's version.
        stateB = try await mirror.resolve(name, keepMine: true, in: stateB, root: folderB.root, token: token)
        (stateB, sent) = try await mirror.push(stateB, root: folderB.root, token: token)
        #expect(sent == 1)
        (stateA, _) = try await mirror.pull(stateA, root: folderA.root, token: token)
        #expect(try String(contentsOf: fileA, encoding: .utf8) == "# Live\n\nFrom B.\n")

        // Remove the test note so the repository stays as it was.
        try FileManager.default.removeItem(at: fileA)
        (stateA, sent) = try await mirror.push(stateA, root: folderA.root, token: token)
        #expect(sent == 1)
        let check = try await mirror.remote.files(
            in: mirror.remote.head(of: repo, token: token).tree,
            of: repo,
            token: token
        )
        #expect(!check.contains { $0.path == name })
    }
}
