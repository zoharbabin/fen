import Foundation

/// One HTTP request, parsed. Header names are lowercased.
struct MCPHTTPRequest: Sendable, Equatable {
    var method: String
    /// The request target as sent, such as `/mcp`.
    var target: String
    var headers: [String: String]
    var body: Data

    init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.target = target
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    /// The target without a query string.
    var path: String {
        String(target.prefix { $0 != "?" && $0 != "#" })
    }
}

struct MCPHTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ status: Int, _ object: Any) -> MCPHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return MCPHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    static func empty(_ status: Int, headers: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: headers)
    }

    func serialized() -> Data {
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for key in all.keys.sorted() {
            head += "\(key): \(Self.cleaned(all[key] ?? ""))\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    /// A header value never holds a line break, so a value can't add a header of its own.
    private static func cleaned(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

/// Reads one request from bytes as they arrive. It takes only what Fen's one endpoint needs:
/// `Content-Length` bodies, no chunked bodies, no pipelining, and hard size limits.
enum MCPHTTPParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1_000_000
    static let maxHeaderCount = 64

    enum Result: Equatable {
        case needMore
        case request(MCPHTTPRequest)
        /// The connection should get this status and close.
        case reject(Int)
    }

    static func parse(_ data: Data) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .reject(431) : .needMore
        }
        guard end.lowerBound <= maxHeaderBytes else { return .reject(431) }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .reject(400) }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2].hasPrefix("HTTP/1."), !first[1].isEmpty,
              first[1].utf8.count <= 2048 else { return .reject(400) }
        guard lines.count - 1 <= maxHeaderCount else { return .reject(431) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .reject(400) }
            let name = line[..<colon].lowercased()
            guard !name.contains(where: { $0 == " " || $0 == "\t" }) else { return .reject(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A repeated header is ambiguous, and which copy a proxy reads can differ.
            guard headers[name] == nil else { return .reject(400) }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return .reject(400) }
        let length: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0, raw.allSatisfy(\.isNumber) else { return .reject(400) }
            length = parsed
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else { return .reject(413) }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .needMore }
        guard body.count == length else { return .reject(400) }
        return .request(MCPHTTPRequest(
            method: String(first[0]),
            target: String(first[1]),
            headers: headers,
            body: Data(body)
        ))
    }
}
