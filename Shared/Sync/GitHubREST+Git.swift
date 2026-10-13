import Foundation

/// The git-data side of `GitHubREST`: read a tree and its files, write one commit.
extension GitHubREST: GitHubRemote {
    func head(of repo: GitHubRepo, token: String?) async throws -> RemoteHead {
        let info: RepoInfo = try await get("", repo, token)
        let ref: RefInfo = try await get("git/ref/heads/\(info.defaultBranch)", repo, token)
        let commit: CommitInfo = try await get("git/commits/\(ref.object.sha)", repo, token)
        return RemoteHead(branch: info.defaultBranch, commit: ref.object.sha, tree: commit.tree.sha)
    }

    func files(in tree: String, of repo: GitHubRepo, token: String?) async throws -> [RemoteFile] {
        var components = components(repo, "git/trees/\(tree)")
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let list: TreeInfo = try await decode(components, repo, token)
        guard !list.truncated else { throw MirrorError.treeTooLarge }
        // Modes 100644 and 100755 are files. Symlinks (120000) and submodules (160000) are left out.
        return list.tree.compactMap { entry in
            guard entry.type == "blob", entry.mode == "100644" || entry.mode == "100755" else { return nil }
            return RemoteFile(path: entry.path, sha: entry.sha, size: entry.size ?? 0)
        }
    }

    func content(of file: RemoteFile, in repo: GitHubRepo, token: String?) async throws -> Data {
        // The raw media type returns the bytes themselves, not base64 inside JSON.
        try await send(
            request(
                components(repo, "git/blobs/\(file.sha)"),
                method: "GET",
                token: token,
                body: nil,
                accept: "application/vnd.github.raw+json"
            ),
            repo: repo
        )
    }

    func commit(
        _ changes: [String: Data?],
        message: String,
        onTopOf head: RemoteHead,
        in repo: GitHubRepo,
        token: String
    ) async throws -> RemoteHead {
        var entries: [TreeEntry] = []
        for (path, data) in changes.sorted(by: { $0.key < $1.key }) {
            let blob: ShaInfo? = if let data {
                try await post("git/blobs", BlobBody(content: data.base64EncodedString()), repo, token)
            } else {
                nil
            }
            entries.append(TreeEntry(path: path, sha: blob?.sha))
        }
        let tree: ShaInfo = try await post("git/trees", TreeBody(baseTree: head.tree, tree: entries), repo, token)
        let commit: ShaInfo = try await post(
            "git/commits",
            CommitBody(message: message, tree: tree.sha, parents: [head.commit]),
            repo,
            token
        )
        do {
            _ = try await send(
                request(
                    components(repo, "git/refs/heads/\(head.branch)"),
                    method: "PATCH",
                    token: token,
                    body: JSONEncoder().encode(RefBody(sha: commit.sha))
                ),
                repo: repo
            )
        } catch let GitSync.SyncError.failed(reason) where reason.contains("not a fast forward") {
            throw MirrorError.branchMoved
        }
        return RemoteHead(branch: head.branch, commit: commit.sha, tree: tree.sha)
    }

    // MARK: - Calls

    private func get<T: Decodable>(_ path: String, _ repo: GitHubRepo, _ token: String?) async throws -> T {
        try await decode(components(repo, path), repo, token)
    }

    private func decode<T: Decodable>(
        _ components: URLComponents,
        _ repo: GitHubRepo,
        _ token: String?
    ) async throws -> T {
        try await read(send(request(components, method: "GET", token: token, body: nil), repo: repo))
    }

    private func post<T: Decodable>(
        _ path: String,
        _ body: some Encodable,
        _ repo: GitHubRepo,
        _ token: String
    ) async throws -> T {
        let payload = try JSONEncoder().encode(body)
        return try await read(send(
            request(components(repo, path), method: "POST", token: token, body: payload),
            repo: repo
        ))
    }

    private func read<T: Decodable>(_ data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw GitSync.SyncError.failed("GitHub sent an answer Fen can't read.")
        }
        return value
    }
}

// MARK: - Bodies and answers

private struct RepoInfo: Decodable {
    let defaultBranch: String

    enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" }
}

private struct RefInfo: Decodable {
    struct Object: Decodable { let sha: String }
    let object: Object
}

private struct CommitInfo: Decodable {
    struct Tree: Decodable { let sha: String }
    let tree: Tree
}

private struct TreeInfo: Decodable {
    struct Entry: Decodable {
        let path: String
        let mode: String
        let type: String
        let sha: String
        let size: Int?
    }

    let tree: [Entry]
    let truncated: Bool
}

private struct ShaInfo: Decodable {
    let sha: String
}

private struct BlobBody: Encodable {
    let content: String
    var encoding = "base64"
}

private struct TreeEntry: Encodable {
    let path: String
    /// `nil` deletes the path, and must be sent as `null`.
    let sha: String?

    enum CodingKeys: String, CodingKey { case path, mode, type, sha }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode("100644", forKey: .mode)
        try container.encode("blob", forKey: .type)
        try container.encode(sha, forKey: .sha)
    }
}

private struct TreeBody: Encodable {
    let baseTree: String
    let tree: [TreeEntry]

    enum CodingKeys: String, CodingKey {
        case baseTree = "base_tree"
        case tree
    }
}

private struct CommitBody: Encodable {
    let message: String
    let tree: String
    let parents: [String]
}

private struct RefBody: Encodable {
    let sha: String
    var force = false
}
