import Foundation

/// A JSON-RPC request that passed every check, with the client that sent it.
struct MCPCall {
    var id: Any?
    var method: String
    var params: [String: Any]
    var version: String
    var client: MCPClient

    /// Clients from before 2026-07-28 open with `initialize` and send no per-request `_meta`.
    var isLegacy: Bool {
        version != MCPProtocol.current
    }
}

enum MCPProtocol {
    static let current = "2026-07-28"
    /// Older revisions Fen still answers, statelessly: no session, no GET stream.
    static let supported = [current, "2025-11-25"]
    static let endpoint = "/mcp"

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    enum Code {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let headerMismatch = -32020
        static let unsupportedVersion = -32022
    }

    /// A JSON-RPC error as an HTTP response. `id` is `nil` when the request had none we can trust.
    static func error(
        _ status: Int,
        id: Any? = nil,
        code: Int,
        _ message: String,
        data: [String: Any]? = nil,
        headers: [String: String] = [:]
    ) -> MCPHTTPResponse {
        var error: [String: Any] = ["code": code, "message": message]
        if let data {
            error["data"] = data
        }
        var response = MCPHTTPResponse.json(status, ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
        response.headers.merge(headers) { $1 }
        return response
    }
}

/// The checks every request passes before any tool runs, in this order: where it came from
/// (Host, Origin), then who sent it, then whether the message is well formed. A failure ends the
/// request with an HTTP error. Pure functions, so tests cover each rule without a socket.
enum MCPRequestGuard {
    enum Verdict {
        case reject(MCPHTTPResponse)
        /// A notification from a known client. The endpoint answers 202 and does nothing else.
        case notification
        case call(MCPCall)
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

    static func check(
        _ request: MCPHTTPRequest,
        port: UInt16,
        authenticate: (String) -> MCPClient?
    ) -> Verdict {
        // Where it came from. A page in a browser can reach 127.0.0.1 through a hostname that
        // points there (DNS rebinding). Such a request carries the attacker's Host or Origin.
        guard let host = request.headers["host"], isLoopback(host: host, port: port) else {
            return .reject(.empty(403))
        }
        if let origin = request.headers["origin"], !isOwnOrigin(origin, port: port) {
            return .reject(.empty(403))
        }
        guard request.path == MCPProtocol.endpoint else { return .reject(.empty(404)) }
        guard request.method == "POST" else { return .reject(.empty(405, headers: ["Allow": "POST"])) }

        // Who sent it.
        guard let token = bearerToken(request.headers["authorization"]), let client = authenticate(token) else {
            return .reject(.empty(401, headers: ["WWW-Authenticate": "Bearer realm=\"Fen\""]))
        }

        // Whether it is well formed.
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .reject(.empty(415))
        }
        return message(in: request, client: client)
    }

    // MARK: - Where from

    static func isLoopback(host header: String, port: UInt16) -> Bool {
        let value = header.lowercased()
        let name: String
        var portText: String?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            name = String(value[...close])
            let rest = value[value.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return false }
                portText = String(rest.dropFirst())
            }
        } else {
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            name = String(parts[0])
            portText = parts.count > 1 ? String(parts[1]) : nil
        }
        guard loopbackHosts.contains(name) else { return false }
        return (portText.flatMap { UInt16($0) } ?? (portText == nil ? 80 : 0)) == port
    }

    /// Only a page served from this very address. Native clients send no `Origin` at all.
    static func isOwnOrigin(_ origin: String, port: UInt16) -> Bool {
        let value = origin.lowercased()
        guard value.hasPrefix("http://") else { return false }
        return isLoopback(host: String(value.dropFirst("http://".count)), port: port)
    }

    private static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Well formed

    private static func message(in request: MCPHTTPRequest, client: MCPClient) -> Verdict {
        guard !request.body.isEmpty else {
            return .reject(MCPProtocol.error(400, code: MCPProtocol.Code.parseError, "The body is empty."))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) else {
            return .reject(MCPProtocol.error(400, code: MCPProtocol.Code.parseError, "The body is not JSON."))
        }
        guard let object = parsed as? [String: Any], object["jsonrpc"] as? String == "2.0",
              let method = object["method"] as? String else {
            return .reject(MCPProtocol.error(
                400,
                code: MCPProtocol.Code.invalidRequest,
                "Send one JSON-RPC 2.0 request or notification. Batches and responses are not accepted."
            ))
        }
        let rawID = object["id"]
        let hasID = rawID != nil && !(rawID is NSNull)
        guard !hasID || rawID is String || rawID is NSNumber else {
            return .reject(MCPProtocol.error(400, code: MCPProtocol.Code.invalidRequest, "The id is not valid."))
        }
        guard hasID else { return .notification }
        let params = object["params"] as? [String: Any] ?? [:]
        let id = rawID

        guard let version = request.headers["mcp-protocol-version"] else {
            return .reject(MCPProtocol.error(
                400,
                id: id,
                code: MCPProtocol.Code.headerMismatch,
                "The MCP-Protocol-Version header is missing."
            ))
        }
        guard MCPProtocol.supported.contains(version) else {
            return .reject(MCPProtocol.error(
                400,
                id: id,
                code: MCPProtocol.Code.unsupportedVersion,
                "Unsupported protocol version",
                data: ["supported": MCPProtocol.supported, "requested": version]
            ))
        }
        if let failure = headerFailure(request, version: version, method: method, params: params, id: id) {
            return .reject(failure)
        }
        return .call(MCPCall(id: id, method: method, params: params, version: version, client: client))
    }

    /// The headers must say what the body says, because a proxy may route on one while Fen acts on
    /// the other. Returns the error response, or `nil` when they agree.
    private static func headerFailure(
        _ request: MCPHTTPRequest,
        version: String,
        method: String,
        params: [String: Any],
        id: Any?
    ) -> MCPHTTPResponse? {
        func mismatch(_ message: String) -> MCPHTTPResponse {
            MCPProtocol.error(400, id: id, code: MCPProtocol.Code.headerMismatch, message)
        }
        let modern = version == MCPProtocol.current
        if let header = request.headers["mcp-method"] {
            guard header == method else { return mismatch("The Mcp-Method header does not match the method.") }
        } else if modern {
            return mismatch("The Mcp-Method header is missing.")
        }
        if method == "tools/call" {
            let name = params["name"] as? String
            if let header = request.headers["mcp-name"] {
                guard let decoded = decodeHeader(header), decoded == name else {
                    return mismatch("The Mcp-Name header does not match the tool name.")
                }
            } else if modern {
                return mismatch("The Mcp-Name header is missing.")
            }
        }
        guard modern else { return nil }
        let meta = params["_meta"] as? [String: Any]
        guard let declared = meta?[MCPProtocol.versionKey] as? String, meta?[MCPProtocol.capabilitiesKey] != nil else {
            return MCPProtocol.error(
                400,
                id: id,
                code: MCPProtocol.Code.invalidParams,
                "Every request needs _meta with the protocol version and the client capabilities."
            )
        }
        return declared == version ? nil : mismatch("The _meta protocol version does not match the header.")
    }

    /// A header value, or the text inside the `=?base64?...?=` form that carries non-ASCII text.
    static func decodeHeader(_ value: String) -> String? {
        let prefix = "=?base64?", suffix = "?="
        guard value.hasPrefix(prefix), value.hasSuffix(suffix), value.count >= prefix.count + suffix.count else {
            return value
        }
        let encoded = String(value.dropFirst(prefix.count).dropLast(suffix.count))
        return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
    }
}
