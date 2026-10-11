@testable import FenCore
import Foundation
import Testing

/// Answers requests in the test, so nothing reaches the network.
final class StubGitHubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?
    private nonisolated(unsafe) static var seen: [URLRequest] = []

    static func install(_ handler: @escaping Handler) -> URLSession {
        lock.withLock {
            self.handler = handler
            seen = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubGitHubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [URLRequest] {
        lock.withLock { seen }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let answer = Self.lock.withLock { () -> (Int, [String: String], Data)? in
            Self.seen.append(request)
            return Self.handler.map { $0(request) }
        }
        guard let answer, let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: answer.0,
                  httpVersion: "HTTP/1.1",
                  headerFields: answer.1
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if (300 ..< 400).contains(answer.0), let location = answer.1["Location"].flatMap(URL.init(string:)) {
            // The session asks its delegate, and follows only if the delegate agrees.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.2)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func json(_ text: String) -> Data {
    Data(text.utf8)
}

private let pull = """
{"number": 7, "html_url": "https://github.com/octo/notes/pull/7", "state": "open", "merged_at": null}
"""

@Suite(.serialized)
struct GitHubRESTTests {
    private let repo = GitHubRepo(owner: "octo", name: "notes")

    @Test func lookingUpAPullRequestAsksForTheBranchOnApiGitHubCom() async throws {
        let session = StubGitHubProtocol.install { _ in (200, [:], json("[\(pull)]")) }
        let found = try await GitHubREST(session: session)
            .pullRequest(head: "fen/changes-1", in: repo, token: "github_pat_fake")
        #expect(try found == PullRequest(
            number: 7,
            url: #require(URL(string: "https://github.com/octo/notes/pull/7")),
            state: .open
        ))

        let request = try #require(StubGitHubProtocol.requests.first)
        #expect(request.url?.host == "api.github.com")
        #expect(request.url?.path == "/repos/octo/notes/pulls")
        let query = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "head" }?.value == "octo:fen/changes-1")
        #expect(query?.first { $0.name == "state" }?.value == "all")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_fake")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test func aMergedPullRequestReadsAsMerged() async throws {
        let body = """
        [{"number": 3, "html_url": "https://github.com/octo/notes/pull/3", "state": "closed", "merged_at": "2026-01-01T00:00:00Z"},
         {"number": 2, "html_url": "https://github.com/octo/notes/pull/2", "state": "closed", "merged_at": null}]
        """
        let session = StubGitHubProtocol.install { _ in (200, [:], json(body)) }
        let found = try await GitHubREST(session: session).pullRequest(head: "b", in: repo, token: nil)
        #expect(found?.number == 3)
        #expect(found?.state == .merged)
        #expect(StubGitHubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aClosedUnmergedPullRequestReadsAsClosed() async throws {
        let body = """
        [{"number": 2, "html_url": "https://github.com/octo/notes/pull/2", "state": "closed", "merged_at": null}]
        """
        let session = StubGitHubProtocol.install { _ in (200, [:], json(body)) }
        #expect(try await GitHubREST(session: session).pullRequest(head: "b", in: repo, token: nil)?.state == .closed)
    }

    @Test func noPullRequestIsNil() async throws {
        let session = StubGitHubProtocol.install { _ in (200, [:], json("[]")) }
        #expect(try await GitHubREST(session: session).pullRequest(head: "b", in: repo, token: nil) == nil)
    }

    @Test func aLinkToAnotherHostIsIgnored() async throws {
        let body = #"[{"number": 1, "html_url": "https://evil.example/pull/1", "state": "open", "merged_at": null}]"#
        let session = StubGitHubProtocol.install { _ in (200, [:], json(body)) }
        #expect(try await GitHubREST(session: session).pullRequest(head: "b", in: repo, token: nil) == nil)
    }

    @Test func openingAPullRequestPostsTitleHeadAndBase() async throws {
        let session = StubGitHubProtocol.install { _ in (201, [:], json(pull)) }
        let opened = try await GitHubREST(session: session).openPullRequest(
            head: "fen/changes-1",
            base: "main",
            title: "Update a.md",
            body: "Sent from Fen.",
            in: repo,
            token: "github_pat_fake"
        )
        #expect(opened.number == 7)
        let request = try #require(StubGitHubProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/octo/notes/pulls")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try request.bodyData().flatMap { try JSONDecoder().decode([String: String].self, from: $0) }
        #expect(sent == ["title": "Update a.md", "head": "fen/changes-1", "base": "main", "body": "Sent from Fen."])
    }

    @Test func aRefusedTokenSaysSo() async throws {
        for status in [401, 403, 404] {
            let session = StubGitHubProtocol.install { _ in (status, [:], json(#"{"message": "Bad credentials"}"#)) }
            await #expect(throws: GitSync.SyncError.authFailed("octo/notes")) {
                _ = try await GitHubREST(session: session).openPullRequest(
                    head: "h", base: "b", title: "t", body: "", in: repo, token: "github_pat_fake"
                )
            }
        }
    }

    @Test func aRefusalGivesGitHubsReason() async throws {
        let body = #"{"message": "Validation Failed", "errors": [{"code": "custom"}]}"#
        let session = StubGitHubProtocol.install { _ in (422, [:], json(body)) }
        do {
            _ = try await GitHubREST(session: session).openPullRequest(
                head: "h", base: "b", title: "t", body: "", in: repo, token: "github_pat_fake"
            )
            Issue.record("Expected a refusal")
        } catch {
            #expect(error.localizedDescription.contains("422"))
            #expect(error.localizedDescription.contains("Validation Failed"))
        }
    }

    @Test func aRedirectIsNeverFollowedSoTheTokenStaysOnApiGitHubCom() async {
        let session = StubGitHubProtocol.install { request in
            request.url?.host == "api.github.com"
                ? (302, ["Location": "https://elsewhere.example/steal"], Data())
                : (200, [:], json("[]"))
        }
        _ = try? await GitHubREST(session: session).pullRequest(head: "b", in: repo, token: "github_pat_fake")
        #expect(StubGitHubProtocol.requests.allSatisfy { $0.url?.host == "api.github.com" })
        #expect(StubGitHubProtocol.requests.count == 1)
    }
}

extension URLRequest {
    /// URLProtocol gets the body as a stream.
    func bodyData() throws -> Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
