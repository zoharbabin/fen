import Foundation
import Network

/// A tiny HTTP/1.1 server for the MCP endpoint (issue #10). It carries bytes to a handler and
/// back. It adds nothing to what Fen can read or write.
///
/// - It listens on `127.0.0.1` only, never on a network address.
/// - One request per connection, then it closes. No keep-alive, no upgrade, no chunked bodies.
/// - Limits: request size (`MCPHTTPParser`), open connections, and time to send a request.
final class MCPServer: @unchecked Sendable {
    static let maxConnections = 16
    static let defaultRequestTimeout: TimeInterval = 10
    /// The address the listener is bound to.
    static let bindAddress = "127.0.0.1"

    typealias Handler = @Sendable (MCPHTTPRequest, UInt16) async -> MCPHTTPResponse

    private let queue = DispatchQueue(label: "fen.mcp.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var open = 0
    private let handler: Handler
    private let requestTimeout: TimeInterval

    init(requestTimeout: TimeInterval = MCPServer.defaultRequestTimeout, handler: @escaping Handler) {
        self.requestTimeout = requestTimeout
        self.handler = handler
    }

    /// Starts listening on `port` (0 picks a free one) and returns the port in use.
    func start(port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() {
                        continuation.resume(returning: listener.port?.rawValue ?? port)
                    }
                case let .failed(error):
                    if once.first() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if once.first() {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
        lock.withLock { self.listener = listener }
        return bound
    }

    func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let allowed = lock.withLock { () -> Bool in
            guard open < Self.maxConnections else { return false }
            open += 1
            return true
        }
        guard allowed else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.lock.withLock { self?.open -= 1 }
            }
        }
        connection.start(queue: queue)
        // A client that connects and sends nothing, or sends a byte a second, is cut off. The
        // limit covers receiving the request only, so a slow tool call still gets its answer.
        // Whichever comes first wins: the whole request, or the time limit.
        let deadline = Once()
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak connection] in
            guard let connection, connection.state != .cancelled, deadline.first() else { return }
            connection.cancel()
        }
        read(connection, buffer: Data(), deadline: deadline)
    }

    private func read(_ connection: NWConnection, buffer: Data, deadline: Once) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            switch MCPHTTPParser.parse(buffer) {
            case let .request(request):
                guard deadline.first() else { return }
                respond(to: request, on: connection)
            case let .reject(status):
                guard deadline.first() else { return }
                send(.empty(status), on: connection)
            case .needMore:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    read(connection, buffer: buffer, deadline: deadline)
                }
            }
        }
    }

    private func respond(to request: MCPHTTPRequest, on connection: NWConnection) {
        let port = lock.withLock { listener?.port?.rawValue } ?? 0
        let handler = handler
        Task {
            await send(handler(request, port), on: connection)
        }
    }

    private func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
