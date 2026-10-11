import Darwin
@testable import FenCore
import Foundation
import Testing

/// Talks to the real listener with plain BSD sockets, so the tests see what any client would.
@Suite("MCP server: a real socket on loopback (issue #10)", .serialized)
@MainActor
struct MCPServerTests {
    struct Reply {
        var text: String
        /// The connection was closed by the server, not abandoned by a timeout.
        var closed: Bool
    }

    /// Opens a connection. Returns the descriptor, or the errno when it fails.
    nonisolated static func connect(host: String, port: UInt16) -> (fd: Int32, error: Int32?) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let code = errno
            close(fd)
            return (-1, code)
        }
        return (fd, nil)
    }

    nonisolated static func readAll(_ fd: Int32) -> Reply {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0 ..< count])
            } else {
                // 0 is a clean close. A reset also means the server ended it. -1 with EAGAIN is our timeout.
                return Reply(text: String(decoding: data, as: UTF8.self), closed: count == 0 || errno != EAGAIN)
            }
        }
    }

    nonisolated static func send(_ bytes: Data, to port: UInt16, host: String = "127.0.0.1") -> Reply {
        let (fd, error) = connect(host: host, port: port)
        guard error == nil else { return Reply(text: "connect failed \(error ?? 0)", closed: true) }
        defer { close(fd) }
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        return readAll(fd)
    }

    func http(
        _ body: Data,
        token: String?,
        host: String? = nil,
        port: UInt16,
        method: String = "tools/list"
    ) async -> Reply {
        var head = "POST /mcp HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
        head += "Content-Type: application/json\r\nMCP-Protocol-Version: \(MCPProtocol.current)\r\n"
        head += "Mcp-Method: \(method)\r\nContent-Length: \(body.count)\r\n"
        if let token {
            head += "Authorization: Bearer \(token)\r\n"
        }
        let bytes = Data((head + "\r\n").utf8) + body
        return await Task.detached { Self.send(bytes, to: port) }.value
    }

    func start(
        _ fixture: MCPFixture,
        timeout: TimeInterval = MCPServer.defaultRequestTimeout
    ) async throws -> (MCPServer, UInt16) {
        let endpoint = fixture.endpoint
        let server = MCPServer(requestTimeout: timeout) { request, port in
            await endpoint.respond(to: request, port: port)
        }
        let port = try await server.start(port: 0)
        return (server, port)
    }

    @Test("A client gets an answer over a real connection, and the connection is closed after it")
    func roundTrip() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let token = try fixture.addClient()
        let (server, port) = try await start(fixture)
        defer { server.stop() }
        let reply = await http(MCPFixture.body("tools/list"), token: token, port: port)
        #expect(reply.text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(reply.text.contains("\"list_documents\""))
        #expect(reply.text.contains("Cache-Control: no-store"))
        #expect(reply.closed)
    }

    @Test("Without a token the answer is 401")
    func noToken() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let (server, port) = try await start(fixture)
        defer { server.stop() }
        let reply = await http(MCPFixture.body("tools/list"), token: nil, port: port)
        #expect(reply.text.hasPrefix("HTTP/1.1 401"))
        #expect(reply.text.contains("WWW-Authenticate"))
    }

    @Test("A DNS rebinding request, with an attacker's Host, is refused over a real socket")
    func rebindingOverSocket() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let token = try fixture.addClient()
        let (server, port) = try await start(fixture)
        defer { server.stop() }
        for host in ["evil.example", "evil.example:\(port)", "127.0.0.1.evil.example:\(port)"] {
            let reply = await http(MCPFixture.body("tools/list"), token: token, host: host, port: port)
            #expect(reply.text.hasPrefix("HTTP/1.1 403"), "\(host)")
            #expect(!reply.text.contains("list_documents"))
        }
    }

    @Test("The listener is bound to loopback. The machine's own network address is refused")
    func loopbackOnly() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let (server, port) = try await start(fixture)
        defer { server.stop() }
        #expect(MCPServer.bindAddress == "127.0.0.1")
        let (loopback, error) = Self.connect(host: "127.0.0.1", port: port)
        #expect(error == nil)
        close(loopback)
        guard let address = Self.nonLoopbackAddress() else {
            Issue.record("This machine has no network address besides loopback, so the check can't run.")
            return
        }
        // Control: a listener on every address must be reachable here. If it isn't, a firewall or VPN
        // drops traffic to this address, and a refusal from Fen's port would prove nothing.
        let open = Self.listenOnAllAddresses()
        defer { close(open.fd) }
        let control = await Task.detached { Self.reachable(host: address, port: open.port) }.value
        guard control else {
            Issue.record("This machine can't reach its own address \(address), so the check can't run.")
            return
        }
        let reachable = await Task.detached { Self.reachable(host: address, port: port) }.value
        #expect(!reachable)
    }

    /// Whether a TCP connection to `host:port` succeeds within two seconds.
    nonisolated static func reachable(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return true
        }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 2000) == 1 else { return false }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure == 0
    }

    /// A plain listener on 0.0.0.0, for the control above.
    nonisolated static func listenOnAllAddresses() -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(fd, 4)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    /// A non-loopback IPv4 address of this machine that is up, if there is one.
    nonisolated static func nonLoopbackAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let sockaddr = entry.pointee.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sockaddr,
                socklen_t(sockaddr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0
            else { continue }
            return String(cString: host)
        }
        return nil
    }

    @Test("A request that is too big gets 413 before its body is read")
    func tooBig() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let (server, port) = try await start(fixture)
        defer { server.stop() }
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 50000000\r\n\r\n"
        let reply = await Task.detached { Self.send(Data(head.utf8), to: port) }.value
        #expect(reply.text.hasPrefix("HTTP/1.1 413"))
    }

    @Test("A client that connects and says nothing is cut off")
    func slowClient() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let (server, port) = try await start(fixture, timeout: 0.3)
        defer { server.stop() }
        let started = Date()
        let reply = await Task.detached { () -> Reply in
            let (fd, _) = Self.connect(host: "127.0.0.1", port: port)
            defer { close(fd) }
            return Self.readAll(fd)
        }.value
        #expect(reply.closed)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test("More than the connection limit at once are turned away")
    func connectionCap() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let (server, port) = try await start(fixture)
        defer { server.stop() }
        let held = (0 ..< MCPServer.maxConnections).map { _ in Self.connect(host: "127.0.0.1", port: port).fd }
        defer { held.forEach { close($0) } }
        // The held connections are accepted in order, so wait until the server has counted them all.
        let turnedAway = try await pollUntilTrue(timeout: .seconds(10)) {
            await Task.detached { () -> Bool in
                let (fd, error) = Self.connect(host: "127.0.0.1", port: port)
                guard error == nil else { return true }
                defer { close(fd) }
                var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var byte: UInt8 = 0
                return read(fd, &byte, 1) == 0 || (read(fd, &byte, 1) < 0 && errno != EAGAIN)
            }.value
        }
        #expect(turnedAway)
    }

    @Test("Stopping the server closes the port")
    func stops() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let (server, port) = try await start(fixture)
        server.stop()
        let refused = try await pollUntilTrue(timeout: .seconds(10)) {
            await Task.detached { Self.connect(host: "127.0.0.1", port: port).error != nil }.value
        }
        #expect(refused)
    }
}
