import CryptoKit
import Foundation
import Observation
import Security

/// What an MCP client may do in the workspaces you enabled it for (issue #10).
public enum MCPLevel: String, Codable, Sendable, CaseIterable {
    case read
    /// Reads, and proposes changes that go through the write gate. They ask first.
    case readAndPropose

    public var title: String {
        switch self {
        case .read: "Read only"
        case .readAndPropose: "Read and propose changes"
        }
    }
}

/// One tool or agent you allowed to connect. Only a hash of its token is stored.
public struct MCPClient: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Unique. Shows in the activity log and matches a client rule in a workspace's write policy.
    public var name: String
    public var tokenHash: String
    /// Workspaces this client may see. A workspace also needs its own MCP switch on.
    public var workspaces: Set<UUID>
    public var level: MCPLevel
    public let createdAt: Date
}

public enum MCPClientError: Error, LocalizedError, Equatable {
    case emptyName
    case nameTaken
    case unknownClient
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Give the client a name."
        case .nameTaken: "Another client already has this name."
        case .unknownClient: "Fen doesn't know this client."
        case let .saveFailed(reason): "Fen couldn't save the client list: \(reason)"
        }
    }
}

/// The clients allowed to use Fen's MCP server, in `~/.fen/mcp-clients.json`.
///
/// A token is shown once, when you create it. Fen keeps its SHA-256 hash. The token is 32 random
/// bytes, so a plain hash is enough: there is nothing to guess.
@MainActor @Observable
public final class MCPClientStore {
    public static let tokenPrefix = "fen_"

    public private(set) var clients: [MCPClient] = []
    public private(set) var loadError: String?

    @ObservationIgnored private let home: FenHome

    public static let shared = MCPClientStore(home: .standard)

    public init(home: FenHome) {
        self.home = home
        load()
    }

    // MARK: - Change

    /// Returns the new client and its token. The token can't be read again.
    public func add(name: String, level: MCPLevel, workspaces: Set<UUID>) throws -> (client: MCPClient, token: String) {
        let name = try validated(name, excluding: nil)
        let token = Self.makeToken()
        let client = MCPClient(
            id: UUID(),
            name: name,
            tokenHash: Self.hash(token),
            workspaces: workspaces,
            level: level,
            createdAt: Date()
        )
        try save(clients + [client])
        return (client, token)
    }

    public func update(_ id: UUID, level: MCPLevel? = nil, workspaces: Set<UUID>? = nil) throws {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { throw MCPClientError.unknownClient }
        var next = clients
        next[index].level = level ?? next[index].level
        next[index].workspaces = workspaces ?? next[index].workspaces
        try save(next)
    }

    /// Replaces the token. The old one stops working at once.
    public func regenerateToken(for id: UUID) throws -> String {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { throw MCPClientError.unknownClient }
        let token = Self.makeToken()
        var next = clients
        next[index].tokenHash = Self.hash(token)
        try save(next)
        return token
    }

    public func remove(_ id: UUID) throws {
        try save(clients.filter { $0.id != id })
    }

    // MARK: - Check

    /// The client that owns `token`, or `nil`. Compares every stored hash in constant time.
    public func client(forToken token: String) -> MCPClient? {
        guard token.hasPrefix(Self.tokenPrefix), token.utf8.count <= 128 else { return nil }
        let presented = Array(Self.hash(token).utf8)
        var match: MCPClient?
        for client in clients where Self.constantTimeEqual(presented, Array(client.tokenHash.utf8)) {
            match = client
        }
        return match
    }

    // MARK: - Tokens

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // The system generator failing is not expected. Fall back to the CryptoKit one.
            bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return tokenPrefix + encoded
    }

    static func hash(_ token: String) -> String {
        ContentHash.of(Data(token.utf8))
    }

    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    // MARK: - Storage

    private func validated(_ name: String, excluding id: UUID?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPClientError.emptyName }
        let taken = clients.contains { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard !taken else { throw MCPClientError.nameTaken }
        return String(trimmed.prefix(80))
    }

    private func load() {
        guard let data = try? Data(contentsOf: home.mcpClientsFile) else { return }
        do {
            clients = try JSONDecoder().decode([MCPClient].self, from: data)
        } catch {
            // Keep the list empty. Nobody connects until you add a client again.
            loadError = "Fen couldn't read the MCP client list, so no client can connect."
        }
    }

    private func save(_ next: [MCPClient]) throws {
        do {
            try home.ensureExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: home.mcpClientsFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.mcpClientsFile.path)
        } catch {
            throw MCPClientError.saveFailed(error.localizedDescription)
        }
        clients = next
        loadError = nil
    }
}
