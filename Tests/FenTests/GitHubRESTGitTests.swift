@testable import FenCore
import Foundation
import Testing

@Suite(.serialized)
struct GitHubRESTGitTests {
    private let repo = GitHubRepo(owner: "octo", name: "notes")
    private let head = RemoteHead(branch: "main", commit: "c1", tree: "t1")

    private func body(_ request: URLRequest) throws -> Data {
        try #require(try request.bodyData())
    }

    @Test func headReadsTheDefaultBranchItsCommitAndItsTree() async throws {
        let session = StubGitHubProtocol.install { request in
            switch request.url?.path {
            case "/repos/octo/notes": (200, [:], Data(#"{"default_branch": "trunk"}"#.utf8))
            case "/repos/octo/notes/git/ref/heads/trunk": (200, [:], Data(#"{"object": {"sha": "c9"}}"#.utf8))
            case "/repos/octo/notes/git/commits/c9": (200, [:], Data(#"{"tree": {"sha": "t9"}}"#.utf8))
            default: (404, [:], Data())
            }
        }
        let found = try await GitHubREST(session: session).head(of: repo, token: "github_pat_fake")
        #expect(found == RemoteHead(branch: "trunk", commit: "c9", tree: "t9"))
        #expect(StubGitHubProtocol.requests.allSatisfy { $0.url?.host == "api.github.com" })
        #expect(StubGitHubProtocol.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_fake"
        })
    }

    @Test func everyRequestSkipsTheLocalCacheSoTheNewestCommitIsAlwaysSeen() async throws {
        let session = StubGitHubProtocol.install { request in
            switch request.url?.path {
            case "/repos/octo/notes": (200, [:], Data(#"{"default_branch": "main"}"#.utf8))
            case "/repos/octo/notes/git/ref/heads/main": (200, [:], Data(#"{"object": {"sha": "c1"}}"#.utf8))
            default: (200, [:], Data(#"{"tree": {"sha": "t1"}}"#.utf8))
            }
        }
        _ = try await GitHubREST(session: session).head(of: repo, token: "github_pat_fake")
        #expect(!StubGitHubProtocol.requests.isEmpty)
        #expect(StubGitHubProtocol.requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
    }

    @Test func theFileListKeepsFilesAndLeavesOutFoldersSymlinksAndSubmodules() async throws {
        let body = """
        {"truncated": false, "tree": [
         {"path": "a.md", "mode": "100644", "type": "blob", "sha": "s1", "size": 5},
         {"path": "run.sh", "mode": "100755", "type": "blob", "sha": "s2", "size": 7},
         {"path": "docs", "mode": "040000", "type": "tree", "sha": "s3"},
         {"path": "link", "mode": "120000", "type": "blob", "sha": "s4", "size": 3},
         {"path": "mod", "mode": "160000", "type": "commit", "sha": "s5"}]}
        """
        let session = StubGitHubProtocol.install { _ in (200, [:], Data(body.utf8)) }
        let files = try await GitHubREST(session: session).files(in: "t1", of: repo, token: nil)
        #expect(files == [RemoteFile(path: "a.md", sha: "s1", size: 5), RemoteFile(path: "run.sh", sha: "s2", size: 7)])
        let request = try #require(StubGitHubProtocol.requests.first)
        #expect(request.url?.path == "/repos/octo/notes/git/trees/t1")
        #expect(request.url?.query == "recursive=1")
    }

    @Test func aCutShortFileListIsRefused() async throws {
        let session = StubGitHubProtocol.install { _ in (200, [:], Data(#"{"truncated": true, "tree": []}"#.utf8)) }
        await #expect(throws: MirrorError.treeTooLarge) {
            _ = try await GitHubREST(session: session).files(in: "t1", of: repo, token: nil)
        }
    }

    @Test func aFileIsFetchedAsRawBytes() async throws {
        let bytes = Data([0x23, 0x20, 0x41, 0x0A])
        let session = StubGitHubProtocol.install { _ in (200, [:], bytes) }
        let data = try await GitHubREST(session: session)
            .content(of: RemoteFile(path: "a.md", sha: "s1", size: 4), in: repo, token: nil)
        #expect(data == bytes)
        let request = try #require(StubGitHubProtocol.requests.first)
        #expect(request.url?.path == "/repos/octo/notes/git/blobs/s1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
    }

    @Test func aCommitSendsBlobsATreeWithNullForDeletesACommitAndANonForcedRefUpdate() async throws {
        let session = StubGitHubProtocol.install { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/repos/octo/notes/git/blobs"): (201, [:], Data(#"{"sha": "b1"}"#.utf8))
            case ("POST", "/repos/octo/notes/git/trees"): (201, [:], Data(#"{"sha": "t2"}"#.utf8))
            case ("POST", "/repos/octo/notes/git/commits"): (201, [:], Data(#"{"sha": "c2"}"#.utf8))
            case ("PATCH", "/repos/octo/notes/git/refs/heads/main"): (200, [:], Data("{}".utf8))
            default: (404, [:], Data())
            }
        }
        let made = try await GitHubREST(session: session).commit(
            ["a.md": Data("hi".utf8), "gone.md": nil],
            message: "Update 2 notes",
            onTopOf: head,
            in: repo,
            token: "github_pat_fake"
        )
        #expect(made == RemoteHead(branch: "main", commit: "c2", tree: "t2"))
        let sent = StubGitHubProtocol.requests
        #expect(sent.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "POST /repos/octo/notes/git/blobs",
            "POST /repos/octo/notes/git/trees",
            "POST /repos/octo/notes/git/commits",
            "PATCH /repos/octo/notes/git/refs/heads/main",
        ])
        let blob = try #require(try JSONSerialization.jsonObject(with: body(sent[0])) as? [String: Any])
        #expect(blob["content"] as? String == Data("hi".utf8)
            .base64EncodedString() && blob["encoding"] as? String == "base64")
        let tree = try String(bytes: body(sent[1]), encoding: .utf8) ?? ""
        #expect(tree.contains(#""base_tree":"t1""#))
        #expect(tree.contains(#""sha":null"#), "A delete must be sent as null")
        let commit = try #require(try JSONSerialization.jsonObject(with: body(sent[2])) as? [String: Any])
        #expect(commit["parents"] as? [String] == ["c1"] && commit["tree"] as? String == "t2")
        let ref = try #require(try JSONSerialization.jsonObject(with: body(sent[3])) as? [String: Any])
        #expect(ref["sha"] as? String == "c2" && ref["force"] as? Bool == false)
    }

    @Test func aBranchThatMovedIsReportedSoTheSyncCanPullAndRetry() async throws {
        let session = StubGitHubProtocol.install { request in
            request.httpMethod == "PATCH"
                ? (422, [:], Data(#"{"message": "Update is not a fast forward"}"#.utf8))
                : (201, [:], Data(#"{"sha": "x"}"#.utf8))
        }
        await #expect(throws: MirrorError.branchMoved) {
            _ = try await GitHubREST(session: session)
                .commit(["a.md": Data("hi".utf8)], message: "m", onTopOf: head, in: repo, token: "github_pat_fake")
        }
    }

    @Test func aRedirectIsNeverFollowed() async throws {
        let session = StubGitHubProtocol.install { _ in
            (302, ["Location": "https://evil.example/steal"], Data())
        }
        await #expect(throws: (any Error).self) {
            _ = try await GitHubREST(session: session).head(of: repo, token: "github_pat_fake")
        }
        #expect(StubGitHubProtocol.requests.allSatisfy { $0.url?.host == "api.github.com" })
    }

    @Test func aTokenGitHubRefusesAsksForANewOneAndARateLimitSaysSo() async throws {
        var session = StubGitHubProtocol.install { _ in (404, [:], Data()) }
        await #expect(throws: GitSync.SyncError.authFailed(repo.title)) {
            _ = try await GitHubREST(session: session).head(of: repo, token: "github_pat_fake")
        }
        session = StubGitHubProtocol.install { _ in (403, ["X-RateLimit-Remaining": "0"], Data()) }
        do {
            _ = try await GitHubREST(session: session).head(of: repo, token: nil)
            Issue.record("A rate limit should throw")
        } catch let GitSync.SyncError.failed(reason) {
            #expect(reason.contains("too many requests"))
        }
    }
}
