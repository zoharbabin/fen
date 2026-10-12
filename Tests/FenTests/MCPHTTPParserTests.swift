@testable import FenCore
import Foundation
import Testing

@Suite("MCP HTTP parser limits (issue #10)")
struct MCPHTTPParserTests {
    func parse(_ text: String) -> MCPHTTPParser.Result {
        MCPHTTPParser.parse(Data(text.utf8))
    }

    @Test("A complete request is parsed, with lowercased header names")
    func complete() {
        let result = parse("POST /mcp?a=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}")
        guard case let .request(request) = result else {
            Issue.record("expected a request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["host"] == "x")
        #expect(request.body == Data("{}".utf8))
    }

    @Test("Half a request waits for more bytes")
    func partial() {
        #expect(parse("POST /mcp HTTP/1.1\r\nHost: x") == .needMore)
        #expect(parse("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nab") == .needMore)
    }

    @Test("A body larger than the limit is refused before it is read")
    func bodyLimit() {
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: \(MCPHTTPParser.maxBodyBytes + 1)\r\n\r\n"
        #expect(parse(head) == .reject(413))
    }

    @Test("A header block larger than the limit is refused, finished or not")
    func headerLimit() {
        let long = String(repeating: "a", count: MCPHTTPParser.maxHeaderBytes + 10)
        #expect(parse("POST /mcp HTTP/1.1\r\nX: \(long)") == .reject(431))
        #expect(parse("POST /mcp HTTP/1.1\r\nX: \(long)\r\n\r\n") == .reject(431))
        let many = (0 ... MCPHTTPParser.maxHeaderCount).map { "H\($0): v" }.joined(separator: "\r\n")
        #expect(parse("POST /mcp HTTP/1.1\r\n\(many)\r\n\r\n") == .reject(431))
    }

    @Test("Ambiguous or unsupported framing is refused", arguments: [
        "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
        "POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: 1x\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}{}",
        "POST /mcp HTTP/1.1\r\nBad Header: v\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nno colon\r\n\r\n",
        "POST /mcp\r\n\r\n",
        "POST /mcp HTTP/2\r\n\r\n",
    ])
    func malformed(text: String) {
        #expect(parse(text) == .reject(400))
    }

    @Test("A response never lets a header value add a header")
    func headerInjection() {
        let response = MCPHTTPResponse(status: 200, headers: ["X-A": "one\r\nSet-Cookie: bad=1"])
        let text = String(data: response.serialized(), encoding: .utf8) ?? ""
        #expect(!text.contains("\r\nSet-Cookie:"))
        #expect(text.contains("Content-Length: 0"))
        #expect(text.contains("Cache-Control: no-store"))
        #expect(!text.lowercased().contains("access-control"))
    }
}
