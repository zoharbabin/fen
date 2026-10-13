import Foundation

/// A pull request Fen opened for a workspace's changes (issue #61).
struct PullRequest: Equatable, Sendable {
    enum State: String, Sendable {
        case open
        case merged
        case closed
    }

    var number: Int
    var url: URL
    var state: State
    /// Whether GitHub can't merge it as it is. `nil` when GitHub hasn't worked it out yet, or it isn't open.
    var hasConflicts: Bool?

    init(number: Int, url: URL, state: State, hasConflicts: Bool? = nil) {
        self.number = number
        self.url = url
        self.state = state
        self.hasConflicts = hasConflicts
    }
}

/// The GitHub REST calls push-as-PR mode needs. Git does everything else.
protocol GitHubAPI: Sendable {
    /// The newest pull request whose head is `branch` in `repo`, open or not. `nil` when there is none.
    func pullRequest(head branch: String, in repo: GitHubRepo, token: String?) async throws -> PullRequest?
    func openPullRequest(
        head: String,
        base: String,
        title: String,
        body: String,
        in repo: GitHubRepo,
        token: String
    ) async throws -> PullRequest
}

/// Talks to `api.github.com` and nowhere else. The token goes in the `Authorization` header of those
/// requests only, and a redirect is never followed, so it can't reach another host.
struct GitHubREST: GitHubAPI {
    static let host = "api.github.com"

    var session: URLSession = .shared

    func pullRequest(head branch: String, in repo: GitHubRepo, token: String?) async throws -> PullRequest? {
        var components = baseComponents(repo)
        components.queryItems = [
            URLQueryItem(name: "head", value: "\(repo.owner):\(branch)"),
            URLQueryItem(name: "state", value: "all"),
            URLQueryItem(name: "per_page", value: "10"),
        ]
        let data = try await send(request(components, method: "GET", token: token, body: nil), repo: repo)
        guard let list = try? JSONDecoder().decode([Item].self, from: data) else {
            throw GitSync.SyncError.failed("GitHub sent an answer Fen can't read.")
        }
        guard var pull = list.max(by: { $0.number < $1.number }).flatMap(\.pullRequest) else { return nil }
        if pull.state == .open {
            pull.hasConflicts = try? await conflicts(of: pull.number, in: repo, token: token)
        }
        return pull
    }

    /// The list answer doesn't say if a pull request can merge, so this asks for the one pull request.
    /// GitHub works it out in the background, so the first answer can be `nil`.
    private func conflicts(of number: Int, in repo: GitHubRepo, token: String?) async throws -> Bool? {
        var components = baseComponents(repo)
        components.path += "/\(number)"
        let data = try await send(request(components, method: "GET", token: token, body: nil), repo: repo)
        guard let item = try? JSONDecoder().decode(Item.self, from: data) else { return nil }
        if item.mergeable == false || item.mergeableState == "dirty" {
            return true
        }
        return item.mergeable == true ? false : nil
    }

    func openPullRequest(
        head: String,
        base: String,
        title: String,
        body: String,
        in repo: GitHubRepo,
        token: String
    ) async throws -> PullRequest {
        let payload = try JSONEncoder().encode(["title": title, "head": head, "base": base, "body": body])
        let data = try await send(
            request(baseComponents(repo), method: "POST", token: token, body: payload),
            repo: repo
        )
        guard let item = try? JSONDecoder().decode(Item.self, from: data), let pull = item.pullRequest else {
            throw GitSync.SyncError.failed("GitHub sent an answer Fen can't read.")
        }
        return pull
    }

    // MARK: - Request

    private struct Item: Decodable {
        var number: Int
        var htmlURL: URL
        var state: String
        var mergedAt: String?
        var mergeable: Bool?
        var mergeableState: String?

        enum CodingKeys: String, CodingKey {
            case number, state, mergeable
            case mergeableState = "mergeable_state"
            case htmlURL = "html_url"
            case mergedAt = "merged_at"
        }

        var pullRequest: PullRequest? {
            guard htmlURL.scheme == "https", htmlURL.host == "github.com" else { return nil }
            let state: PullRequest.State = mergedAt != nil ? .merged : (state == "open" ? .open : .closed)
            return PullRequest(number: number, url: htmlURL, state: state)
        }
    }

    private struct ErrorBody: Decodable {
        var message: String?
    }

    private func baseComponents(_ repo: GitHubRepo) -> URLComponents {
        components(repo, "pulls")
    }

    /// `https://api.github.com/repos/<owner>/<name>/<path>`.
    func components(_ repo: GitHubRepo, _ path: String) -> URLComponents {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/repos/\(repo.owner)/\(repo.name)" + (path.isEmpty ? "" : "/" + path)
        return components
    }

    func request(
        _ components: URLComponents,
        method: String,
        token: String?,
        body: Data?,
        accept: String = "application/vnd.github+json"
    ) throws -> URLRequest {
        guard let url = components.url else { throw GitSync.SyncError.failed("Fen can't build the GitHub address.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Fen", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ request: URLRequest, repo: GitHubRepo) async throws -> Data {
        let (data, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else {
            throw GitSync.SyncError.failed("GitHub didn't answer.")
        }
        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0":
            throw GitSync.SyncError.failed("GitHub says Fen has made too many requests. Try again in a few minutes.")
        case 401, 403, 404:
            // GitHub answers 404 for a private repository the token can't see.
            throw GitSync.SyncError.authFailed(repo.title)
        default:
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            throw GitSync.SyncError.failed(
                "GitHub refused the request (\(http.statusCode))" + (reason.map { ": \($0.prefix(160))" } ?? ".")
            )
        }
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
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
