@testable import FenCore
import Foundation
import Testing

/// Two workspaces for MCP tests: `Notes` has MCP on, `Private` leaves it off. The index is built
/// before the first call, so reads don't depend on a file being open anywhere.
@MainActor
struct MCPFixture {
    static let port: UInt16 = 4321

    let home: TempHome
    let notes: TempFolder
    let secret: TempFolder
    let library: WorkspaceLibrary
    let gate: WriteGate
    let clients: MCPClientStore
    let endpoint: MCPEndpoint
    let notesID: UUID
    let privateID: UUID

    static let notesFiles: [String: String] = [
        "meetings/standup.md": "---\ntype: Meeting\n---\n\n# Standup\n\nWe talked about the zebra rollout. See [[Jane Doe]].\n",
        "meetings/retro.md": "---\ntype: Meeting\n---\n\n# Retro\n\nWhat went well.\n",
        "people/Jane Doe.md": "---\ntype: Person\n---\n\n# Jane Doe\n\nLeads the [standup](../meetings/standup.md).\n",
        "ideas.md": "# Ideas\n\nA note with no type.\n",
        ".hidden.md": "# Hidden\n\nhiddenword\n",
        ".env": "TOKEN=abc\n",
    ]

    init() async throws {
        home = try TempHome()
        notes = try TempFolder("mcp-notes")
        secret = try TempFolder("mcp-private")
        for (path, text) in Self.notesFiles {
            try notes.write(path, text)
        }
        try secret.write("plan.md", "# Plan\n\nThe walrus launch plan.\n")
        try SchemaStore(root: notes.root).create(DocumentSchema(types: [
            DocumentType("Meeting", description: "A meeting", fields: [SchemaField("attendees", .list)]),
            DocumentType("Person", description: "A person"),
        ]))
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: FakeEmbedder())
        let workspace = try library.add(folder: notes.root, name: "Notes")
        let other = try library.add(folder: secret.root, name: "Private")
        try library.updateSettings(id: workspace.id) { $0.mcpAccess = .enabled }
        let ready = try await pollUntilTrue(timeout: .seconds(30)) {
            let status = library.indexStatus(for: workspace.id)
            let otherStatus = library.indexStatus(for: other.id)
            return status.phase == .idle && status.documents == 4 && otherStatus.phase == .idle
                && otherStatus.documents == 1
        }
        try #require(ready)
        self.library = library
        gate = WriteGate(library: library)
        clients = MCPClientStore(home: home.home)
        endpoint = MCPEndpoint(library: library, gate: gate, clients: clients)
        notesID = workspace.id
        privateID = other.id
    }

    func cleanUp() {
        home.cleanUp()
        notes.cleanUp()
        secret.cleanUp()
    }

    func text(_ path: String) throws -> String {
        try String(contentsOf: notes.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Adds a client and returns its token.
    func addClient(
        _ name: String = "Agent",
        level: MCPLevel = .read,
        workspaces: Set<UUID>? = nil
    ) throws -> String {
        try clients.add(name: name, level: level, workspaces: workspaces ?? [notesID]).token
    }

    // MARK: - Requests

    static func headers(
        method: String,
        name: String? = nil,
        token: String?,
        version: String = MCPProtocol.current
    ) -> [String: String] {
        var headers = [
            "Host": "127.0.0.1:\(port)",
            "Content-Type": "application/json",
            "MCP-Protocol-Version": version,
            "Mcp-Method": method,
        ]
        if let name {
            headers["Mcp-Name"] = name
        }
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    static func body(_ method: String, _ params: [String: Any] = [:], id: Int = 1, legacy: Bool = false) -> Data {
        var params = params
        if !legacy {
            params["_meta"] = [
                MCPProtocol.versionKey: MCPProtocol.current,
                MCPProtocol.capabilitiesKey: [String: Any](),
            ]
        }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }

    func rpc(
        _ method: String,
        _ params: [String: Any] = [:],
        token: String?,
        version: String = MCPProtocol.current
    ) async -> MCPHTTPResponse {
        let name = params["name"] as? String
        let request = MCPHTTPRequest(
            method: "POST",
            target: "/mcp",
            headers: Self.headers(method: method, name: name, token: token, version: version),
            body: Self.body(method, params, legacy: version != MCPProtocol.current)
        )
        return await endpoint.respond(to: request, port: Self.port)
    }

    /// Calls a tool. Returns the structured result and whether the tool reported an error.
    func tool(_ name: String, _ arguments: [String: Any] = [:], token: String?) async -> (
        data: [String: Any],
        isError: Bool,
        status: Int
    ) {
        let response = await rpc("tools/call", ["name": name, "arguments": arguments], token: token)
        let result = Self.result(response)
        return (
            result?["structuredContent"] as? [String: Any] ?? [:],
            result?["isError"] as? Bool ?? false,
            response.status
        )
    }

    static func object(_ response: MCPHTTPResponse) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    }

    static func result(_ response: MCPHTTPResponse) -> [String: Any]? {
        object(response)?["result"] as? [String: Any]
    }

    static func errorCode(_ response: MCPHTTPResponse) -> Int? {
        (object(response)?["error"] as? [String: Any])?["code"] as? Int
    }
}
