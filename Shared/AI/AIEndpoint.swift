import Foundation

/// A provider address, classified by where it sends content (issue #4).
///
/// - Loopback means `localhost`, `127.x.x.x`, or `::1`, and nothing else. Names like
///   `localhost.example.com` are remote.
/// - Everything that is not loopback is `.remote` for AI data access, including a LAN host.
/// - Plain `http` is allowed for loopback and private-network addresses. Anything else needs `https`.
public struct AIEndpoint: Sendable, Equatable {
    public let url: URL

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw AIError.invalidEndpoint(trimmed)
        }
        self.url = url
        if scheme == "http", !Self.isLoopback(host: host), !Self.isPrivateNetwork(host: host) {
            throw AIError.insecureEndpoint(host: host)
        }
    }

    public var host: String {
        url.host(percentEncoded: false) ?? ""
    }

    public var isLoopback: Bool {
        Self.isLoopback(host: host)
    }

    public var destination: ModelDestination {
        isLoopback ? .local : .remote
    }

    /// Joins path parts below the base URL, keeping any path the base already has (`/v1`).
    func appending(_ path: String) -> URL {
        path.split(separator: "/").reduce(url) { $0.appendingPathComponent(String($1)) }
    }

    // MARK: - Classification

    static func isLoopback(host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "::1" {
            return true
        }
        return ipv4(name)?.first == 127
    }

    static func isPrivateNetwork(host: String) -> Bool {
        let name = host.lowercased()
        if name.hasSuffix(".local") {
            return true
        }
        guard let parts = ipv4(name) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }

    /// Exactly four decimal parts, each 0 to 255. Short forms like `127.1` are not accepted, so they
    /// count as remote.
    private static func ipv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part), value <= 255 else { return nil }
            numbers.append(value)
        }
        return numbers
    }
}
