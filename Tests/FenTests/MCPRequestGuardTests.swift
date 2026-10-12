@testable import FenCore
import Foundation
import Testing

@Suite("MCP request guard: where from, who, well formed (issue #10)")
@MainActor
struct MCPRequestGuardTests {
    static let port = MCPFixture.port
    static let token = "fen_token"
    static let client = MCPClient(
        id: UUID(),
        name: "Agent",
        tokenHash: "x",
        workspaces: [],
        level: .read,
        createdAt: Date()
    )

    func verdict(
        _ request: MCPHTTPRequest,
        accepting: String = token
    ) -> MCPRequestGuard.Verdict {
        MCPRequestGuard.check(request, port: Self.port, authenticate: { $0 == accepting ? Self.client : nil })
    }

    func request(
        host: String? = "127.0.0.1:\(port)",
        origin: String? = nil,
        method: String = "POST",
        path: String = "/mcp",
        token: String? = token,
        contentType: String? = "application/json",
        version: String? = MCPProtocol.current,
        rpcMethod: String? = "tools/list",
        name: String? = nil,
        body: Data? = nil
    ) -> MCPHTTPRequest {
        var headers: [String: String] = [:]
        headers["Host"] = host
        headers["Origin"] = origin
        headers["Authorization"] = token.map { "Bearer \($0)" }
        headers["Content-Type"] = contentType
        headers["MCP-Protocol-Version"] = version
        headers["Mcp-Method"] = rpcMethod
        headers["Mcp-Name"] = name
        return MCPHTTPRequest(
            method: method,
            target: path,
            headers: headers,
            body: body ?? MCPFixture.body(rpcMethod ?? "tools/list")
        )
    }

    func status(_ verdict: MCPRequestGuard.Verdict) -> Int? {
        if case let .reject(response) = verdict {
            return response.status
        }
        return nil
    }

    func code(_ verdict: MCPRequestGuard.Verdict) -> Int? {
        if case let .reject(response) = verdict {
            return MCPFixture.errorCode(response)
        }
        return nil
    }

    @Test("A well-formed request from a known client passes")
    func passes() {
        guard case let .call(call) = verdict(request()) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.method == "tools/list")
        #expect(!call.isLegacy)
    }

    @Test("Host must be loopback on our port. A rebinding host is refused", arguments: [
        "evil.example:4321",
        "127.0.0.1.evil.example:4321",
        "localhost.evil.example:4321",
        "192.168.1.5:4321",
        "0.0.0.0:4321",
        "127.0.0.1:9999",
        "127.0.0.1",
        "127.0.0.1:abc",
        "[::1]x",
        "",
    ])
    func hostRefused(host: String) {
        #expect(status(verdict(request(host: host))) == 403)
    }

    @Test("A missing Host header is refused")
    func noHost() {
        #expect(status(verdict(request(host: nil))) == 403)
    }

    @Test(
        "Host in the usual loopback forms passes",
        arguments: ["127.0.0.1:4321", "localhost:4321", "[::1]:4321", "LOCALHOST:4321"]
    )
    func hostAccepted(host: String) {
        if case .call = verdict(request(host: host)) {} else {
            Issue.record("expected \(host) to pass")
        }
    }

    @Test("The Host check runs before authentication, so a rebinding page learns nothing about tokens")
    func hostBeforeAuth() {
        #expect(status(verdict(request(host: "evil.example:4321", token: "wrong"))) == 403)
    }

    @Test("Any foreign Origin is refused. Only our own origin passes", arguments: [
        "https://evil.example", "http://evil.example:4321", "http://localhost:80", "null", "http://127.0.0.1:1",
        "https://127.0.0.1:4321",
    ])
    func originRefused(origin: String) {
        #expect(status(verdict(request(origin: origin))) == 403)
    }

    @Test("Our own origin passes")
    func ownOrigin() {
        if case .call = verdict(request(origin: "http://127.0.0.1:4321")) {} else {
            Issue.record("expected own origin to pass")
        }
    }

    @Test("Only POST on /mcp. Other methods and paths fail")
    func methodAndPath() {
        #expect(status(verdict(request(method: "GET"))) == 405)
        #expect(status(verdict(request(method: "DELETE"))) == 405)
        #expect(status(verdict(request(method: "OPTIONS"))) == 405)
        #expect(status(verdict(request(path: "/other"))) == 404)
        #expect(status(verdict(request(path: "/mcp/"))) == 404)
        if case .call = verdict(request(path: "/mcp?x=1")) {} else {
            Issue.record("a query string on /mcp is allowed")
        }
    }

    @Test("No token, a wrong token, and a token in the query string are all 401")
    func authentication() {
        #expect(status(verdict(request(token: nil))) == 401)
        #expect(status(verdict(request(token: "fen_wrong"))) == 401)
        #expect(status(verdict(request(path: "/mcp?token=\(Self.token)", token: nil))) == 401)
        if case let .reject(response) = verdict(request(token: nil)) {
            #expect(response.headers["WWW-Authenticate"] == "Bearer realm=\"Fen\"")
        }
    }

    @Test("A body that is not one JSON-RPC message is refused with the JSON-RPC code")
    func malformedBody() {
        let cases: [(Data, Int)] = [
            (Data(), MCPProtocol.Code.parseError),
            (Data("nope".utf8), MCPProtocol.Code.parseError),
            (Data("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]".utf8), MCPProtocol.Code.invalidRequest),
            (Data("{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}".utf8), MCPProtocol.Code.invalidRequest),
            (Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8), MCPProtocol.Code.invalidRequest),
            (Data("{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}".utf8), MCPProtocol.Code.invalidRequest),
        ]
        for (body, expected) in cases {
            let verdict = verdict(request(body: body))
            #expect(status(verdict) == 400)
            #expect(code(verdict) == expected)
        }
    }

    @Test("A non-JSON content type is 415")
    func contentType() {
        #expect(status(verdict(request(contentType: "text/plain"))) == 415)
        #expect(status(verdict(request(contentType: nil))) == 415)
    }

    @Test("A notification from a known client is accepted without a version header")
    func notification() {
        let body = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
        if case .notification = verdict(request(version: nil, rpcMethod: nil, body: body)) {} else {
            Issue.record("expected a notification")
        }
        #expect(status(verdict(request(token: nil, body: body))) == 401)
    }

    @Test("A missing or unsupported protocol version is 400 and lists what Fen supports")
    func protocolVersion() {
        #expect(code(verdict(request(version: nil))) == MCPProtocol.Code.headerMismatch)
        let unsupported = verdict(request(version: "1900-01-01"))
        #expect(status(unsupported) == 400)
        #expect(code(unsupported) == MCPProtocol.Code.unsupportedVersion)
        if case let .reject(response) = unsupported {
            let error = MCPFixture.object(response)?["error"] as? [String: Any]
            let data = error?["data"] as? [String: Any]
            #expect(data?["supported"] as? [String] == MCPProtocol.supported)
            #expect(data?["requested"] as? String == "1900-01-01")
        }
    }

    @Test("Headers must match the body: method, tool name, and _meta version")
    func headerMismatch() {
        #expect(code(verdict(request(rpcMethod: "tools/call"))) == MCPProtocol.Code.headerMismatch)
        #expect(code(verdict(request(rpcMethod: nil))) == MCPProtocol.Code.headerMismatch)
        let call = MCPFixture.body("tools/call", ["name": "search"])
        #expect(code(verdict(request(rpcMethod: "tools/call", name: "get_document", body: call)))
            == MCPProtocol.Code.headerMismatch)
        #expect(code(verdict(request(rpcMethod: "tools/call", name: nil, body: call)))
            == MCPProtocol.Code.headerMismatch)
        if case .call = verdict(request(rpcMethod: "tools/call", name: "search", body: call)) {} else {
            Issue.record("a matching name passes")
        }
        // The _meta version says one thing and the header another.
        let other = Data("""
        {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{
        "io.modelcontextprotocol/protocolVersion":"2025-11-25","io.modelcontextprotocol/clientCapabilities":{}}}}
        """.utf8)
        #expect(code(verdict(request(body: other))) == MCPProtocol.Code.headerMismatch)
    }

    @Test("A 2026-07-28 request without _meta is invalid params")
    func missingMeta() {
        let bare = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}".utf8)
        let verdict = verdict(request(body: bare))
        #expect(status(verdict) == 400)
        #expect(code(verdict) == MCPProtocol.Code.invalidParams)
    }

    @Test("Mcp-Name in the base64 form is decoded before it is compared")
    func base64Name() {
        let encoded = "=?base64?" + Data("search".utf8).base64EncodedString() + "?="
        let call = MCPFixture.body("tools/call", ["name": "search"])
        if case .call = verdict(request(rpcMethod: "tools/call", name: encoded, body: call)) {} else {
            Issue.record("expected the encoded name to match")
        }
        #expect(MCPRequestGuard.decodeHeader("=?base64?!!!?=") == nil)
    }

    @Test("An older client (2025-11-25) needs no _meta")
    func legacy() {
        let body = MCPFixture.body("tools/list", legacy: true)
        guard case let .call(call) = verdict(request(version: "2025-11-25", body: body)) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.isLegacy)
    }
}
