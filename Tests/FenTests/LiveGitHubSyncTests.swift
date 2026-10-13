@testable import FenCore
import Foundation
import Testing

/// Clone, edit, push, pull and a conflict against a real GitHub repository (issues #60, #62). It uses a
/// throwaway repo and a fine-grained token you made for just that repo. The token never goes in an
/// environment variable or a tracked file: keep it in a file only you can read.
///
///     chmod 600 ~/.fen-live-github-token
///     FEN_LIVE_GITHUB_REPO=zoharbabin/fen-sync-test FEN_LIVE_GITHUB_TOKEN_FILE=~/.fen-live-github-token \
///         swift test --no-parallel --filter LiveGitHubSync
@Suite(
    "Live GitHub sync (issues #60, #62)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["FEN_LIVE_GITHUB_REPO"] != nil)
)
@MainActor
struct LiveGitHubSyncTests {
    private func credentials() throws -> (repo: GitHubRepo, token: String) {
        let env = ProcessInfo.processInfo.environment
        let slug = try #require(env["FEN_LIVE_GITHUB_REPO"]).split(separator: "/").map(String.init)
        try #require(slug.count == 2)
        let path = try #require(env["FEN_LIVE_GITHUB_TOKEN_FILE"]) as NSString
        let url = URL(fileURLWithPath: path.expandingTildeInPath)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        try #require(mode == 0o600, "Run chmod 600 on the token file.")
        let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return (GitHubRepo(owner: slug[0], name: slug[1]), token)
    }

    @Test("a real repository clones, takes an edit, pushes, pulls, and refuses a stale push")
    func roundTrip() async throws {
        let (repo, token) = try credentials()
        let home = try TempHome()
        let parentA = try TempFolder("live-gh-a")
        let parentB = try TempFolder("live-gh-b")
        defer { home.cleanUp()
            parentA.cleanUp()
            parentB.cleanUp()
        }
        let secrets = MemorySecretStore()
        let sync = GitSync(git: GitFixture.tool, secrets: secrets)
        let library = WorkspaceLibrary(home: home.home, watching: false)
        let unique = "fen-live-\(UUID().uuidString.prefix(8)).md"

        // A wrong token must fail and must not be kept.
        await #expect(throws: (any Error).self) {
            _ = try await GitHubCloner(library: library, sync: sync)
                .clone(repo, token: "github_pat_" + String(repeating: "x", count: 40), into: parentB.root)
        }
        #expect(try secrets.read(account: repo.tokenAccount) == nil)

        // Clone with the real token. It is kept only after the clone worked.
        let workspace = try await GitHubCloner(library: library, sync: sync)
            .clone(repo, token: token, into: parentA.root)
        let rootA = URL(fileURLWithPath: workspace.path)
        #expect(try secrets.read(account: repo.tokenAccount) == token)
        #expect(try await sync.status(at: rootA, fetch: true).isClean)

        // Edit, commit and push. A second clone sees it after a pull.
        try "# Live\n\nFirst line.\n".write(to: rootA.appendingPathComponent(unique), atomically: true, encoding: .utf8)
        #expect(try await sync.commitChanges(at: rootA) == 1)
        #expect(try await sync.push(at: rootA) == .pushed(commits: 1))

        let libraryB = try WorkspaceLibrary(home: TempHome().home, watching: false)
        let workspaceB = try await GitHubCloner(library: libraryB, sync: sync)
            .clone(repo, token: token, into: parentB.root)
        let rootB = URL(fileURLWithPath: workspaceB.path)
        #expect(FileManager.default.fileExists(atPath: rootB.appendingPathComponent(unique).path))

        // Both sides edit the same file. The first push wins, the second is refused without force.
        try "# Live\n\nFrom A.\n".write(to: rootA.appendingPathComponent(unique), atomically: true, encoding: .utf8)
        try "# Live\n\nFrom B.\n".write(to: rootB.appendingPathComponent(unique), atomically: true, encoding: .utf8)
        #expect(try await sync.commitChanges(at: rootA) == 1)
        #expect(try await sync.push(at: rootA) == .pushed(commits: 1))
        #expect(try await sync.commitChanges(at: rootB) == 1)
        #expect(try await sync.push(at: rootB) == .rejected)
        #expect(try await sync.pull(at: rootB) == .diverged)

        // Clean up the remote: remove the test file through A so the repo stays tidy.
        try FileManager.default.removeItem(at: rootA.appendingPathComponent(unique))
        #expect(try await sync.commitChanges(at: rootA) == 1)
        #expect(try await sync.push(at: rootA) == .pushed(commits: 1))
    }
}
