import Foundation

/// Which notes changed since the last conflict check (issue #94).
///
/// In a git workspace the boundary is the commit the last run ended on, and `git diff` against it
/// names the changed files, plus the files git doesn't track yet. Elsewhere, or when that commit is
/// gone, the boundary is each file's hash at the last run. Either way a file counts as changed only
/// if its hash differs from the one the last run saw, so an edit that is still uncommitted isn't
/// checked twice.
struct ConflictDelta: Equatable {
    /// Paths to check, in path order.
    var changed: [String]
    /// The paths came from `git diff`. Otherwise every file was hashed.
    var usedGit: Bool
    /// `HEAD` now, to store when the run ends.
    var head: String?
}

enum ConflictDeltaFinder {
    /// - Parameters:
    ///   - paths: Every note in the workspace.
    ///   - hashes: Hashes a file's content, or `nil` if it can't be read. Called only for files that may have changed.
    static func find(
        root: URL,
        paths: [String],
        state: ConflictState,
        git: GitTool?,
        hash: @Sendable (String) -> String?
    ) async -> ConflictDelta {
        let head = await currentHead(root: root, git: git)
        var candidates = Set(paths)
        var usedGit = false
        if let git, let boundary = state.commit, head != nil,
           let names = await changedSince(boundary, root: root, git: git) {
            candidates.formIntersection(names)
            usedGit = true
        }
        let changed = candidates.sorted().filter { path in
            guard let current = hash(path) else { return false }
            return state.files[path]?.hash != current
        }
        return ConflictDelta(changed: changed, usedGit: usedGit, head: head)
    }

    /// `HEAD` of the repository around `root`, or `nil` when there is no git, no repository or no commit.
    static func currentHead(root: URL, git: GitTool?) async -> String? {
        guard let git, let output = try? await git.run(["rev-parse", "--verify", "-q", "HEAD"], in: root),
              output.succeeded, output.text.count == 40 else { return nil }
        return output.text
    }

    /// Files that differ from `boundary` in the working tree, or `nil` if git can't say. Paths are
    /// relative to `root`, which may be a subfolder of the repository.
    private static func changedSince(_ boundary: String, root: URL, git: GitTool) async -> Set<String>? {
        guard let exists = try? await git.run(["cat-file", "-e", "\(boundary)^{commit}"], in: root),
              exists.succeeded,
              let diff = try? await git.run(["diff", "--name-only", "-z", "--relative", boundary, "--"], in: root),
              diff.succeeded,
              let untracked = try? await git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: root),
              untracked.succeeded else { return nil }
        return Set(names(diff.stdout) + names(untracked.stdout))
    }

    private static func names(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }
}
