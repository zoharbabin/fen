@testable import FenCore
import Foundation

/// A GitHub repository in memory. It keeps one branch, and a commit builds on the newest one only.
final class FakeRepository: GitHubRemote, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var version = 1
    private(set) var commits: [[String: Data?]] = []
    private(set) var messages: [String] = []
    /// Runs once, just before the next commit is checked, so a test can move the branch under Fen.
    var beforeNextCommit: (() -> Void)?

    init(_ initial: [String: String]) {
        files = initial.mapValues { Data($0.utf8) }
    }

    func edit(_ path: String, _ text: String?) {
        lock.withLock {
            files[path] = text.map { Data($0.utf8) }
            version += 1
        }
    }

    func text(_ path: String) -> String? {
        lock.withLock { files[path].flatMap { String(bytes: $0, encoding: .utf8) } }
    }

    private var currentHead: RemoteHead {
        RemoteHead(branch: "main", commit: "commit-\(version)", tree: "tree-\(version)")
    }

    private var failure: (any Error)?

    /// The next call to `head` throws `error`, as GitHub does for a token it refuses.
    func failNext(with error: any Error) {
        lock.withLock { failure = error }
    }

    func head(of _: GitHubRepo, token _: String?) async throws -> RemoteHead {
        try lock.withLock {
            if let error = failure {
                failure = nil
                throw error
            }
            return currentHead
        }
    }

    func files(in _: String, of _: GitHubRepo, token _: String?) async throws -> [RemoteFile] {
        lock.withLock {
            files.map { RemoteFile(path: $0.key, sha: GitHubMirror.blobSHA(of: $0.value), size: $0.value.count) }
        }
    }

    func content(of file: RemoteFile, in _: GitHubRepo, token _: String?) async throws -> Data {
        try lock.withLock {
            guard let data = files.values.first(where: { GitHubMirror.blobSHA(of: $0) == file.sha }) else {
                throw GitSync.SyncError.failed("No such blob")
            }
            return data
        }
    }

    func commit(
        _ changes: [String: Data?],
        message: String,
        onTopOf head: RemoteHead,
        in _: GitHubRepo,
        token _: String
    ) async throws -> RemoteHead {
        let hook = lock.withLock { () -> (() -> Void)? in
            defer { beforeNextCommit = nil }
            return beforeNextCommit
        }
        hook?()
        return try lock.withLock {
            guard head == currentHead else { throw MirrorError.branchMoved }
            for (path, data) in changes {
                files[path] = data
            }
            commits.append(changes)
            messages.append(message)
            version += 1
            return currentHead
        }
    }
}
