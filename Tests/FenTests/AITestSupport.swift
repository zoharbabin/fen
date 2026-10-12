@testable import FenCore
import Foundation
import Network

/// A tiny HTTP server on a loopback port, for tests that need real sockets. One request per
/// connection. The body is close-delimited unless the handler sets `Content-Length`.
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Keep the connection open after the chunks, as a slow stream does.
        var holdOpen = false
    }

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var connectionCount = 0
    private var closedCount = 0
    private let handler: @Sendable (Request) -> Response

    private init(listener: NWListener, port: UInt16, handler: @escaping @Sendable (Request) -> Response) {
        self.listener = listener
        self.port = port
        self.handler = handler
    }

    static func start(_ handler: @escaping @Sendable (Request) -> Response) async throws -> LoopbackServer {
        let listener: NWListener
        listener = try NWListener(using: .tcp, on: .any)
        let box = ServerBox()
        // NWListener refuses to start (EINVAL) without a connection handler.
        listener.newConnectionHandler = { connection in box.server?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Flag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setOnce(), let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    }
                case let .failed(error):
                    if resumed.setOnce() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "LoopbackServer.start"))
        }
        let server = LoopbackServer(listener: listener, port: port, handler: handler)
        box.server = server
        listener.stateUpdateHandler = nil
        return server
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: String {
        "http://localhost:\(port)"
    }

    var requests: [Request] {
        lock.withLock { recorded }
    }

    /// Connections opened, whether or not they sent a request.
    var connections: Int {
        lock.withLock { connectionCount }
    }

    /// Held-open connections the client has closed.
    var clientClosed: Int {
        lock.withLock { closedCount }
    }

    private final class ServerBox: @unchecked Sendable {
        weak var server: LoopbackServer?
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func setOnce() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        lock.withLock { connectionCount += 1 }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let request = Self.parse(buffer) {
                respond(to: request, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                read(connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ data: Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(bytes: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let body = data[range.upperBound...]
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        guard body.count >= expected else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body))
    }

    private func respond(to request: Request, on connection: NWConnection) {
        lock.withLock { recorded.append(request) }
        let response = handler(request)
        var head = "HTTP/1.1 \(response.status) X\r\nConnection: close\r\n"
        for (key, value) in response.headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        response.chunks.forEach { payload.append($0) }
        connection.send(content: payload, completion: .contentProcessed { [self] _ in
            if response.holdOpen {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] _, _, _, _ in
                    lock.withLock { closedCount += 1 }
                    connection.cancel()
                }
            } else {
                connection.cancel()
            }
        })
    }
}

/// An in-memory `SecretStore`, so provider tests never touch the real keychain.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    func write(_ secret: String, account: String) throws {
        lock.withLock { values[account] = secret }
    }

    func delete(account: String) throws {
        lock.withLock { values[account] = nil }
    }

    var allSecrets: [String] {
        lock.withLock { Array(values.values) }
    }
}

/// A home folder in a temp directory, deleted by `cleanUp()`.
struct TempHome {
    let folder: TempFolder
    let home: FenHome

    init() throws {
        folder = try TempFolder("home")
        home = FenHome(root: folder.root.appendingPathComponent(".fen"))
    }

    func cleanUp() {
        folder.cleanUp()
    }
}

func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var pieces: [String] = []
    for try await piece in stream {
        pieces.append(piece)
    }
    return pieces
}
