@testable import FenCore
import Foundation
import Testing

/// Answers requests in the test, so nothing reaches the network.
final class StubUpdateProtocol: URLProtocol, @unchecked Sendable {
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
        configuration.protocolClasses = [StubUpdateProtocol.self]
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

private func release(_ tag: String, page: String? = nil) -> Data {
    let url = page ?? "https://github.com/zoharbabin/fen/releases/tag/\(tag)"
    return Data(#"{"tag_name": "\#(tag)", "html_url": "\#(url)", "name": "Fen"}"#.utf8)
}

struct ReleaseVersionTests {
    @Test func versionsCompareByNumberNotByText() throws {
        #expect(try #require(ReleaseVersion("v0.10.0")) > #require(ReleaseVersion("0.9.9")))
        #expect(try #require(ReleaseVersion("0.5.2")) > #require(ReleaseVersion("0.5.1")))
        #expect(try #require(ReleaseVersion("1.0")) == #require(ReleaseVersion("1.0.0")))
        #expect(try #require(ReleaseVersion("1.0.1")) > #require(ReleaseVersion("1.0")))
    }

    @Test func textThatIsNotAVersionIsRefused() {
        for text in ["", "latest", "v1.x", "1..2", "v"] {
            #expect(ReleaseVersion(text) == nil, "\(text)")
        }
    }

    @Test func aDevSuffixMarksABuildFromSource() throws {
        #expect(try #require(ReleaseVersion("0.0.0-dev")).isDevelopment)
        #expect(try !#require(ReleaseVersion("0.5.1")).isDevelopment)
    }
}

@Suite(.serialized)
struct UpdateCheckerTests {
    @Test func aNewerReleaseIsOfferedWithItsPage() async throws {
        let session = StubUpdateProtocol.install { _ in (200, [:], release("v0.6.0")) }
        let outcome = try await UpdateChecker.check(current: "0.5.1", session: session)
        #expect(try outcome == .available(
            version: "0.6.0",
            page: #require(URL(string: "https://github.com/zoharbabin/fen/releases/tag/v0.6.0"))
        ))
    }

    @Test func theSameOrANewerBuildIsUpToDate() async throws {
        let session = StubUpdateProtocol.install { _ in (200, [:], release("v0.5.1")) }
        #expect(try await UpdateChecker.check(current: "0.5.1", session: session) == .upToDate(current: "0.5.1"))
        #expect(try await UpdateChecker.check(current: "0.6.0", session: session) == .upToDate(current: "0.6.0"))
    }

    @Test func aBuildFromSourceIsNotCompared() async throws {
        let session = StubUpdateProtocol.install { _ in (200, [:], release("v0.5.1")) }
        #expect(try await UpdateChecker.check(current: "0.0.0-dev", session: session) == .development(latest: "0.5.1"))
        #expect(try await UpdateChecker.check(current: "", session: session) == .development(latest: "0.5.1"))
    }

    @Test func theRequestGoesToApiGitHubComWithNoCredentials() async throws {
        let session = StubUpdateProtocol.install { _ in (200, [:], release("v0.6.0")) }
        _ = try await UpdateChecker.check(current: "0.5.1", session: session)
        let request = try #require(StubUpdateProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/zoharbabin/fen/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
    }

    @Test func aPageOutsideFensReleasesIsNeverOffered() async throws {
        for page in [
            "https://evil.example/zoharbabin/fen/releases/tag/v9.0.0",
            "http://github.com/zoharbabin/fen/releases/tag/v9.0.0",
            "https://github.com/someone/else/releases/tag/v9.0.0",
            "https://github.com.evil.example/zoharbabin/fen/releases/tag/v9.0.0",
        ] {
            let session = StubUpdateProtocol.install { _ in (200, [:], release("v9.0.0", page: page)) }
            await #expect(throws: UpdateChecker.CheckError.unreadable, "\(page)") {
                try await UpdateChecker.check(current: "0.5.1", session: session)
            }
        }
    }

    @Test func garbageAndErrorsGiveAReasonNotACrash() async throws {
        let garbage = StubUpdateProtocol.install { _ in (200, [:], Data("<html>".utf8)) }
        await #expect(throws: UpdateChecker.CheckError.unreadable) {
            try await UpdateChecker.check(current: "0.5.1", session: garbage)
        }
        let limited = StubUpdateProtocol.install { _ in (403, [:], Data()) }
        await #expect(throws: UpdateChecker.CheckError.unreachable("GitHub answered 403. Try again later.")) {
            try await UpdateChecker.check(current: "0.5.1", session: limited)
        }
        let offline = StubUpdateProtocol.install { _ in (0, [:], Data()) }
        await #expect(throws: UpdateChecker.CheckError.self) {
            try await UpdateChecker.check(current: "0.5.1", session: offline)
        }
    }

    @Test func aRedirectIsNotFollowed() async throws {
        let session = StubUpdateProtocol.install { request in
            request.url?.host == "api.github.com"
                ? (302, ["Location": "https://elsewhere.example/steal"], Data())
                : (200, [:], release("v9.0.0"))
        }
        await #expect(throws: UpdateChecker.CheckError.self) {
            try await UpdateChecker.check(current: "0.5.1", session: session)
        }
        #expect(StubUpdateProtocol.requests.allSatisfy { $0.url?.host == "api.github.com" })
        #expect(StubUpdateProtocol.requests.count == 1)
    }
}
