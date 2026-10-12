@testable import FenCore
import Foundation
import ObjectiveC
import Testing

/// Counts every HTTP(S) request any `URLSession` in this process tries to start. Registered with
/// `URLProtocol.registerClass`, so it also sees sessions made from the default and ephemeral
/// configurations. It fails each request, so a positive control never reaches a real server.
final class RequestSpy: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var seen: [String] = []

    static var urls: [String] {
        lock.withLock { seen }
    }

    static func reset() {
        lock.withLock { seen = [] }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        lock.withLock { seen.append(request.url?.absoluteString ?? "?") }
        return true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Counts calls that make or fetch a `URLSession`: `+sharedSession` and both
/// `+sessionWithConfiguration:` factories, which is what `URLSession.shared` and
/// `URLSession(configuration:)` call.
private typealias FactoryWithDelegate =
    @convention(block) (AnyObject, URLSessionConfiguration, AnyObject?, AnyObject?) -> AnyObject

final class SessionCreationSpy: @unchecked Sendable {
    static let shared = SessionCreationSpy()
    private let lock = NSLock()
    private var count = 0
    private var saved: [(Method, IMP)] = []

    var created: Int {
        lock.withLock { count }
    }

    private func bump() {
        lock.withLock { count += 1 }
    }

    func install() {
        guard lock.withLock({ saved.isEmpty }) else { return }
        // `registerClass` only reaches `URLSession.shared`. Sessions made from a configuration use
        // that configuration's own `protocolClasses`, so put the spy first on every new one.
        for name in ["defaultSessionConfiguration", "ephemeralSessionConfiguration"] {
            swizzle(URLSessionConfiguration.self, name) { original in
                let call = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector) -> AnyObject).self)
                return { (receiver: AnyObject) -> AnyObject in
                    let configuration = call(receiver, Selector((name)))
                    if let configuration = configuration as? URLSessionConfiguration {
                        configuration.protocolClasses = [RequestSpy.self] + (configuration.protocolClasses ?? [])
                    }
                    return configuration
                } as @convention(block) (AnyObject) -> AnyObject
            }
        }
        let target: AnyClass = URLSession.self
        swizzle(target, "sharedSession") { original in
            let call = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector) -> AnyObject).self)
            return { [self] (receiver: AnyObject) -> AnyObject in
                bump()
                return call(receiver, Selector(("sharedSession")))
            } as @convention(block) (AnyObject) -> AnyObject
        }
        swizzle(target, "sessionWithConfiguration:") { original in
            let call = unsafeBitCast(
                original,
                to: (@convention(c) (AnyObject, Selector, URLSessionConfiguration) -> AnyObject).self
            )
            return { [self] (receiver: AnyObject, configuration: URLSessionConfiguration) -> AnyObject in
                bump()
                return call(receiver, Selector(("sessionWithConfiguration:")), configuration)
            } as @convention(block) (AnyObject, URLSessionConfiguration) -> AnyObject
        }
        swizzle(target, "sessionWithConfiguration:delegate:delegateQueue:") { original in
            let call = unsafeBitCast(
                original,
                to: (@convention(c) (AnyObject, Selector, URLSessionConfiguration, AnyObject?, AnyObject?) -> AnyObject)
                    .self
            )
            let block: FactoryWithDelegate = { [self] receiver, configuration, delegate, queue in
                bump()
                return call(
                    receiver,
                    Selector(("sessionWithConfiguration:delegate:delegateQueue:")),
                    configuration,
                    delegate,
                    queue
                )
            }
            return block
        }
    }

    func uninstall() {
        let restore = lock.withLock { () -> [(Method, IMP)] in
            defer { saved = [] }
            return saved
        }
        for (method, original) in restore {
            method_setImplementation(method, original)
        }
    }

    private func swizzle(_ target: AnyClass, _ name: String, _ makeBlock: (IMP) -> Any) {
        guard let method = class_getClassMethod(target, Selector((name))) else { return }
        let original = method_getImplementation(method)
        method_setImplementation(method, imp_implementationWithBlock(makeBlock(original)))
        lock.withLock { saved.append((method, original)) }
    }
}

@Suite("Indexing makes no network call (issue #35)", .serialized)
@MainActor
struct IndexingNoNetworkTests {
    @Test("the watchers can see a request and a session when one is made (positive control)")
    func watchersWork() async throws {
        URLProtocol.registerClass(RequestSpy.self)
        SessionCreationSpy.shared.install()
        defer {
            SessionCreationSpy.shared.uninstall()
            URLProtocol.unregisterClass(RequestSpy.self)
            RequestSpy.reset()
        }
        RequestSpy.reset()
        let before = SessionCreationSpy.shared.created

        let ephemeral = URLSession(configuration: .ephemeral)
        _ = URLSession.shared
        #expect(SessionCreationSpy.shared.created >= before + 2)

        let url = try #require(URL(string: "https://fen-watcher-check.invalid/"))
        _ = try? await ephemeral.data(from: url)
        #expect(RequestSpy.urls.count == 1, "ephemeral session")
        let defaultSession = URLSession(configuration: .default)
        _ = try? await defaultSession.data(from: url)
        #expect(RequestSpy.urls.count == 2, "default session")
        _ = try? await URLSession.shared.data(from: url)
        #expect(RequestSpy.urls.count == 3, "shared session")
    }

    @Test("a real indexing run with the on-device model starts no request and creates no URLSession")
    func realRunStaysOffline() async throws {
        let provider = AppleSentenceEmbeddingProvider()
        try #require(provider.isAvailable, "The on-device sentence model isn't installed on this machine.")
        let home = try TempHome()
        let folder = try TempFolder("no-network")
        defer {
            home.cleanUp()
            folder.cleanUp()
        }
        for number in 0 ..< 40 {
            try folder.write(
                "notes/note-\(number).md",
                "# Note \(number)\nWe talk about backups and bicycles here.\n## Plan\nBook the flight in March.\n"
            )
        }
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: provider)

        URLProtocol.registerClass(RequestSpy.self)
        SessionCreationSpy.shared.install()
        defer {
            SessionCreationSpy.shared.uninstall()
            URLProtocol.unregisterClass(RequestSpy.self)
            RequestSpy.reset()
        }
        RequestSpy.reset()
        let sessionsBefore = SessionCreationSpy.shared.created

        let workspace = try library.add(folder: folder.root, name: "Offline")
        let done = try await pollUntilTrue(timeout: .seconds(60)) {
            let status = library.indexStatus(for: workspace.id)
            return library.state(for: workspace.id).hasScanned && status.phase == .idle && status.documents == 40
        }
        #expect(done)
        let status = library.indexStatus(for: workspace.id)
        // The real model ran: vectors were stored, and a meaning-only query finds a note.
        #expect(status.isSemantic)
        #expect(status.embeddedChunks == status.chunks)
        let results = await library.search("vacation flight", scope: .all, destination: .shownToUser)
        #expect(!results.isEmpty)

        #expect(RequestSpy.urls.isEmpty, "requests started: \(RequestSpy.urls)")
        #expect(SessionCreationSpy.shared.created == sessionsBefore)
    }
}
