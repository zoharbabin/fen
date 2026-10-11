import Foundation
import Observation

/// Starts and stops Fen's MCP server (issue #10). The server is off until you turn it on in
/// Settings, and it only runs on the Mac. A phone or tablet can't keep a server alive in the
/// background, so iOS never starts one.
@MainActor @Observable
public final class MCPController {
    public enum Status: Equatable {
        case off
        case running(port: UInt16)
        case failed(String)
    }

    public nonisolated static let defaultPort: UInt16 = 47890

    public private(set) var status = Status.off

    @ObservationIgnored private let endpoint: MCPEndpoint
    @ObservationIgnored private let library: WorkspaceLibrary
    @ObservationIgnored private var server: MCPServer?

    public static let shared = MCPController(library: .shared, gate: .shared, clients: .shared)

    public init(library: WorkspaceLibrary, gate: WriteGate, clients: MCPClientStore) {
        self.library = library
        endpoint = MCPEndpoint(library: library, gate: gate, clients: clients)
    }

    public var isRunning: Bool {
        if case .running = status {
            return true
        }
        return false
    }

    /// Call once at launch. Starts the server if you turned it on earlier.
    public func launch() {
        #if os(macOS)
            if Preferences.shared.mcpServerEnabled {
                start(port: Preferences.shared.mcpPort)
            }
        #endif
    }

    /// Turns the server on or off and remembers the choice.
    public func setEnabled(_ enabled: Bool) {
        Preferences.shared.mcpServerEnabled = enabled
        if enabled {
            start(port: Preferences.shared.mcpPort)
        } else {
            stop()
        }
    }

    public func start(port: UInt16) {
        stop()
        library.start()
        let endpoint = endpoint
        let server = MCPServer { request, port in
            await endpoint.respond(to: request, port: port)
        }
        self.server = server
        Task {
            do {
                let bound = try await server.start(port: port)
                if self.server === server {
                    status = .running(port: bound)
                } else {
                    server.stop()
                }
            } catch {
                if self.server === server {
                    self.server = nil
                    status = .failed(Self.explain(error, port: port))
                }
            }
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        status = .off
    }

    private static func explain(_ error: Error, port: UInt16) -> String {
        "Fen can't listen on port \(port). Another app may use it. Pick a different port. "
            + "(\(error.localizedDescription))"
    }
}
