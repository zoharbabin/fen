@testable import FenCore
import Foundation
import Testing

@Suite("MCP client store: tokens are shown once and never kept (issue #10)")
@MainActor
struct MCPClientStoreTests {
    func makeStore() throws -> (MCPClientStore, TempHome) {
        let home = try TempHome()
        return (MCPClientStore(home: home.home), home)
    }

    @Test("A token has the prefix and a token resolves to its client")
    func addAndFind() throws {
        let (store, home) = try makeStore()
        defer { home.cleanUp() }
        let added = try store.add(name: " Agent ", level: .readAndPropose, workspaces: [])
        #expect(added.token.hasPrefix("fen_"))
        #expect(added.token.count > 40)
        #expect(added.client.name == "Agent")
        #expect(store.client(forToken: added.token)?.id == added.client.id)
        #expect(store.client(forToken: added.token + "x") == nil)
        #expect(store.client(forToken: "fen_") == nil)
        #expect(store.client(forToken: "") == nil)
        #expect(store.client(forToken: String(repeating: "a", count: 500)) == nil)
    }

    @Test("Only the hash reaches the disk, and the file is private to you")
    func onlyHashStored() throws {
        let (store, home) = try makeStore()
        defer { home.cleanUp() }
        let added = try store.add(name: "Agent", level: .read, workspaces: [])
        let file = home.home.mcpClientsFile
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(added.token))
        #expect(text.contains(added.client.tokenHash))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("Clients survive a restart")
    func persists() throws {
        let (store, home) = try makeStore()
        defer { home.cleanUp() }
        let added = try store.add(name: "Agent", level: .read, workspaces: [UUID()])
        let again = MCPClientStore(home: home.home)
        #expect(again.clients == [added.client])
        #expect(again.client(forToken: added.token) != nil)
    }

    @Test("Names are unique, ignoring case, and must not be empty")
    func names() throws {
        let (store, home) = try makeStore()
        defer { home.cleanUp() }
        _ = try store.add(name: "Agent", level: .read, workspaces: [])
        #expect(throws: MCPClientError.nameTaken) { try store.add(name: "agent", level: .read, workspaces: []) }
        #expect(throws: MCPClientError.emptyName) { try store.add(name: "  ", level: .read, workspaces: []) }
    }

    @Test("A new token replaces the old one at once")
    func regenerate() throws {
        let (store, home) = try makeStore()
        defer { home.cleanUp() }
        let added = try store.add(name: "Agent", level: .read, workspaces: [])
        let fresh = try store.regenerateToken(for: added.client.id)
        #expect(fresh != added.token)
        #expect(store.client(forToken: added.token) == nil)
        #expect(store.client(forToken: fresh)?.id == added.client.id)
    }

    @Test("Update changes level and workspaces. Remove ends access")
    func updateAndRemove() throws {
        let (store, home) = try makeStore()
        defer { home.cleanUp() }
        let added = try store.add(name: "Agent", level: .read, workspaces: [])
        let workspace = UUID()
        try store.update(added.client.id, level: .readAndPropose, workspaces: [workspace])
        #expect(store.client(forToken: added.token)?.level == .readAndPropose)
        #expect(store.client(forToken: added.token)?.workspaces == [workspace])
        try store.remove(added.client.id)
        #expect(store.client(forToken: added.token) == nil)
        #expect(throws: MCPClientError.unknownClient) { try store.update(added.client.id, level: .read) }
        #expect(throws: MCPClientError.unknownClient) { try store.regenerateToken(for: added.client.id) }
    }

    @Test("A damaged file leaves no client able to connect and says so")
    func damagedFile() throws {
        let home = try TempHome()
        defer { home.cleanUp() }
        try home.home.ensureExists()
        try Data("not json".utf8).write(to: home.home.mcpClientsFile)
        let store = MCPClientStore(home: home.home)
        #expect(store.clients.isEmpty)
        #expect(store.loadError != nil)
    }

    @Test("Tokens are different every time")
    func random() {
        let tokens = Set((0 ..< 50).map { _ in MCPClientStore.makeToken() })
        #expect(tokens.count == 50)
    }

    @Test("Comparison is exact")
    func compare() {
        #expect(MCPClientStore.constantTimeEqual(Array("abc".utf8), Array("abc".utf8)))
        #expect(!MCPClientStore.constantTimeEqual(Array("abc".utf8), Array("abd".utf8)))
        #expect(!MCPClientStore.constantTimeEqual(Array("abc".utf8), Array("ab".utf8)))
    }
}
