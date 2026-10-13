import Foundation

/// The newest commit on a repository's default branch.
struct RemoteHead: Equatable, Sendable {
    var branch: String
    var commit: String
    var tree: String
}

/// A file in a repository's tree. `sha` is git's hash of the file's content.
struct RemoteFile: Equatable, Sendable {
    var path: String
    var sha: String
    var size: Int
}

/// The GitHub git-data calls a mirror needs (issue #60). iOS can't run git, so a GitHub workspace there
/// reads and writes the repository through these calls. `GitHubREST` is the real one.
protocol GitHubRemote: Sendable {
    func head(of repo: GitHubRepo, token: String?) async throws -> RemoteHead
    /// Every regular file in the tree. Throws when GitHub cuts the list short.
    func files(in tree: String, of repo: GitHubRepo, token: String?) async throws -> [RemoteFile]
    func content(of file: RemoteFile, in repo: GitHubRepo, token: String?) async throws -> Data
    /// Puts one commit on `head.branch`, on top of `head`. A `nil` value deletes that path. It never
    /// forces: if the branch moved, it throws `MirrorError.branchMoved`.
    func commit(
        _ changes: [String: Data?],
        message: String,
        onTopOf head: RemoteHead,
        in repo: GitHubRepo,
        token: String
    ) async throws -> RemoteHead
}
