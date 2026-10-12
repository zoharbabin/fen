@testable import FenCore
import Foundation
import Testing

@Suite("AIEndpoint")
struct AIEndpointTests {
    @Test("loopback addresses are local", arguments: [
        "http://localhost:11434", "http://127.0.0.1:1234/v1", "http://127.5.5.5", "http://[::1]:8080",
        "https://localhost",
    ])
    func loopbackIsLocal(address: String) throws {
        let endpoint = try AIEndpoint(address)
        #expect(endpoint.isLoopback)
        #expect(endpoint.destination == .local)
    }

    @Test("look-alike and other addresses are remote and need https", arguments: [
        "http://localhost.evil.com", "http://127.0.0.1.evil.com", "http://127.1", "http://0.0.0.0",
        "http://1.2.3.4", "http://api.openai.com/v1", "http://172.32.0.1",
    ])
    func lookAlikesAreRemote(address: String) throws {
        #expect(throws: AIError.self) { try AIEndpoint(address) }
        let secure = try AIEndpoint(address.replacingOccurrences(of: "http://", with: "https://"))
        #expect(!secure.isLoopback)
        #expect(secure.destination == .remote)
    }

    @Test("private network hosts may use http but still count as remote", arguments: [
        "http://192.168.1.5:1234", "http://10.0.0.2", "http://172.16.4.4", "http://my-mac.local:11434",
        "http://169.254.1.1",
    ])
    func privateNetworkIsRemote(address: String) throws {
        let endpoint = try AIEndpoint(address)
        #expect(!endpoint.isLoopback)
        #expect(endpoint.destination == .remote)
    }

    @Test("bad addresses are refused", arguments: [
        "", "   ", "ftp://localhost", "localhost:11434", "not a url", "http://user:secret@localhost",
        "file:///etc/passwd",
    ])
    func badAddresses(address: String) {
        #expect(throws: AIError.self) { try AIEndpoint(address) }
    }

    @Test("appending keeps the path the base already has")
    func appendingKeepsBasePath() throws {
        let endpoint = try AIEndpoint("https://openrouter.ai/api/v1")
        #expect(endpoint.appending("chat/completions")
            .absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        let plain = try AIEndpoint("http://localhost:11434")
        #expect(plain.appending("api/chat").absoluteString == "http://localhost:11434/api/chat")
    }
}

@Suite("AIGateway")
struct AIGatewayTests {
    private func workspace(_ access: AIDataAccess, name: String = "Notes") -> Workspace {
        Workspace(name: name, path: "/tmp/\(name)", settings: WorkspaceSettings(aiDataAccess: access))
    }

    @Test(
        "every AI data access value against every destination",
        arguments: AIDataAccess.allCases, [ModelDestination.local, .remote]
    )
    func matrixIsEnforced(access: AIDataAccess, destination: ModelDestination) throws {
        let allowed = access != .none && (destination == .local || access == .anyConfiguredProvider)
        let space = workspace(access)
        let context = [AIContextItem(workspaceID: space.id, label: "a.md", text: "secret")]
        if allowed {
            try AIGateway.authorize(context: context, destination: destination, workspaces: [space])
        } else {
            #expect(throws: AIError.workspaceDisallows(workspace: "Notes", access: access, destination: destination)) {
                try AIGateway.authorize(context: context, destination: destination, workspaces: [space])
            }
        }
    }

    @Test("content outside any workspace is not gated")
    func nonWorkspaceContent() throws {
        let context = [AIContextItem(workspaceID: nil, label: "selection", text: "hello")]
        try AIGateway.authorize(context: context, destination: .remote, workspaces: [])
    }

    @Test("one disallowed item refuses the whole request")
    func oneBadItemRefusesAll() {
        let open = workspace(.anyConfiguredProvider, name: "Open")
        let closed = workspace(.none, name: "Closed")
        let context = [
            AIContextItem(workspaceID: open.id, label: "a.md", text: "a"),
            AIContextItem(workspaceID: closed.id, label: "b.md", text: "b"),
        ]
        #expect(throws: AIError.workspaceDisallows(workspace: "Closed", access: .none, destination: .local)) {
            try AIGateway.authorize(context: context, destination: .local, workspaces: [open, closed])
        }
    }

    @Test("a workspace Fen doesn't know is refused")
    func unknownWorkspace() {
        let context = [AIContextItem(workspaceID: UUID(), label: "a.md", text: "a")]
        #expect(throws: AIError.unknownWorkspace) {
            try AIGateway.authorize(context: context, destination: .local, workspaces: [])
        }
    }
}
