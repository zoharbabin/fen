import Foundation

/// The version in a release tag such as `v0.5.1`, for comparing with the running app (issue #39).
struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let numbers: [Int]
    /// `0.0.0-dev` and the like: a build from source, not a release.
    let isDevelopment: Bool

    var description: String {
        numbers.map(String.init).joined(separator: ".")
    }

    init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") || core.hasPrefix("V") {
            core.removeFirst()
        }
        let suffix = core.firstIndex(of: "-")
        isDevelopment = suffix != nil
        if let suffix {
            core = String(core[..<suffix])
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        numbers = parts.compactMap(\.self)
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0 ..< count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// Asks GitHub which Fen release is newest. It only reads: it downloads nothing and installs nothing.
/// You open the release page and get the signed, notarized build from there.
///
/// This is the one network call a menu command makes on its own, and it is never run in the background.
/// It talks to `api.github.com` and nowhere else, sends no token and no document, and follows no redirect.
public enum UpdateChecker {
    public enum Outcome: Equatable, Sendable {
        case upToDate(current: String)
        case available(version: String, page: URL)
        /// A build from source has no release to compare with.
        case development(latest: String)
    }

    public enum CheckError: Error, Equatable, LocalizedError {
        case unreachable(String)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case let .unreachable(reason): reason
            case .unreadable: "GitHub sent an answer Fen can't read."
            }
        }
    }

    static let host = "api.github.com"
    static let releasesPath = "/repos/zoharbabin/fen/releases/latest"
    /// Only a page under this path is offered to you.
    static let pagePrefix = "/zoharbabin/fen/releases/"

    /// Fetches the newest release and compares it with `current`, the running app's version.
    public static func check(current: String, session: URLSession = .shared) async throws -> Outcome {
        let latest = try await latestRelease(session: session)
        guard let installed = ReleaseVersion(current), !installed.isDevelopment else {
            return .development(latest: latest.version.description)
        }
        return installed < latest.version
            ? .available(version: latest.version.description, page: latest.page)
            : .upToDate(current: installed.description)
    }

    struct Release: Equatable {
        let version: ReleaseVersion
        let page: URL
    }

    static func latestRelease(session: URLSession) async throws -> Release {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = releasesPath
        guard let url = components.url else { throw CheckError.unreadable }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Fen", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirect())
        } catch {
            throw CheckError.unreachable("Fen couldn't reach GitHub. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else { throw CheckError.unreadable }
        guard http.statusCode == 200 else {
            throw CheckError.unreachable("GitHub answered \(http.statusCode). Try again later.")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Release {
        struct Body: Decodable {
            var tagName: String
            var htmlURL: URL
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              let version = ReleaseVersion(body.tagName),
              body.htmlURL.scheme == "https", body.htmlURL.host == "github.com",
              body.htmlURL.path.hasPrefix(pagePrefix)
        else { throw CheckError.unreadable }
        return Release(version: version, page: body.htmlURL)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
