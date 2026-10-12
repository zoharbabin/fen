import Foundation

/// Branch handling for push-as-PR mode and for holding AI changes back (issue #61).
/// Every step keeps your edits: a branch is made from where you are, and nothing is reset while it
/// holds commits that exist nowhere else.
extension GitSync {
    /// The prefix of the branches Fen makes for a set of changes.
    static let workingBranchPrefix = "fen/changes-"

    static func isWorkingBranch(_ name: String?) -> Bool {
        name?.hasPrefix(workingBranchPrefix) == true
    }

    /// `fen/changes-20260131-094501`, in UTC so two devices don't pick the same name by accident.
    static func workingBranchName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return workingBranchPrefix + formatter.string(from: date)
    }

    /// The branch GitHub treats as the default, such as `main`.
    func defaultBranch(at root: URL) async throws -> String {
        let head = try await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], at: root, allowFailure: true)
        if head.succeeded, head.text.hasPrefix("origin/") {
            return String(head.text.dropFirst("origin/".count))
        }
        let remote = try await git.run(
            ["ls-remote", "--symref", "origin", "HEAD"],
            in: root,
            environment: environment(at: root)
        )
        if remote.succeeded,
           let line = remote.text.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") }) {
            let name = line.dropFirst("ref: refs/heads/".count).split(whereSeparator: \.isWhitespace).first
            if let name {
                return String(name)
            }
        }
        for candidate in ["main", "master"] {
            let known = try await run(
                ["rev-parse", "--verify", "-q", "refs/remotes/origin/\(candidate)"],
                at: root,
                allowFailure: true
            )
            if known.succeeded {
                return candidate
            }
        }
        throw SyncError.failed("Fen can't tell which branch is the default on GitHub.")
    }

    /// Makes `name` at the current commit and switches to it. Uncommitted edits come along.
    func startBranch(_ name: String, at root: URL) async throws {
        try await run(["switch", "--quiet", "-c", name], at: root)
    }

    /// Switches branches when that doesn't touch an edited file. Returns the reason when it can't.
    func switchBranch(to name: String, at root: URL) async throws -> String? {
        let out = try await run(["switch", "--quiet", name], at: root, allowFailure: true)
        return out.succeeded ? nil : Self.firstLine(out.stderr, fallback: "Your changes are in the way.")
    }

    /// Points the local branch `name` at `origin/<name>`. Used for the default branch when its unpushed
    /// commits moved to a pull request branch, so they stay reachable from that branch.
    func resetBranchToRemote(_ name: String, at root: URL, keeping branch: String) async throws {
        let ahead = try await run(["rev-list", "--count", "origin/\(name)..\(name)"], at: root)
        guard ahead.text != "0" else { return }
        let held = try await run(["merge-base", "--is-ancestor", name, branch], at: root, allowFailure: true)
        guard held.succeeded else {
            throw SyncError.failed("Fen kept \(name) as it is, because it has commits that are on no other branch.")
        }
        try await run(["branch", "--force", name, "origin/\(name)"], at: root)
    }

    /// When each of `paths` was last committed. A path never committed is left out.
    func lastCommitDates(of paths: [String], at root: URL) async throws -> [String: Date] {
        var dates: [String: Date] = [:]
        for path in paths {
            let out = try await run(["log", "-1", "--format=%ct", "--", path], at: root, allowFailure: true)
            if out.succeeded, let seconds = TimeInterval(out.text) {
                dates[path] = Date(timeIntervalSince1970: seconds)
            }
        }
        return dates
    }

    /// Commits on the current branch that no remote branch has. Use it when the branch tracks none, so
    /// `Status.ahead` can't say.
    func unpushedCommits(at root: URL) async throws -> Int {
        let out = try await run(["rev-list", "--count", "HEAD", "--not", "--remotes"], at: root)
        return Int(out.text) ?? 0
    }

    func deleteBranch(_ name: String, at root: URL) async throws {
        try await run(["branch", "--delete", "--force", name], at: root)
    }

    /// The first line of the latest commit message.
    func lastSubject(at root: URL) async throws -> String? {
        let out = try await run(["log", "-1", "--format=%s"], at: root, allowFailure: true)
        return out.succeeded && !out.text.isEmpty ? out.text : nil
    }

    /// Paths with changes that aren't committed. Includes new notes.
    func changedFiles(at root: URL) async throws -> [String] {
        try await changedPaths(at: root)
    }
}
