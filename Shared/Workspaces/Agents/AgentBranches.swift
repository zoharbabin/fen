import CryptoKit
import Foundation

/// How an agent's changes are kept in a workspace that is a git repository (issue #93).
public enum AgentBranchMode: String, Codable, Sendable, CaseIterable {
    /// Each MCP client commits to its own `fen/<client>` branch. Your checkout isn't touched.
    case perAgent
    /// Changes land in your files directly, like any other change.
    case inPlace

    public var title: String {
        switch self {
        case .perAgent: "On the agent's own branch"
        case .inPlace: "In place"
        }
    }
}

public enum AgentBranchError: Error, Equatable, LocalizedError {
    /// The branch moved while Fen was writing (a second Fen window, or you, ran git).
    case branchMoved(String)
    /// Another agent holds the claim on this path.
    case claimed(path: String, by: String, until: Date)
    case gitFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .branchMoved(name): "The branch “\(name)” changed while Fen was writing. Try again."
        case let .claimed(path, owner, until):
            "“\(path)” is being created by \(owner) until \(until.formatted(date: .omitted, time: .shortened)). "
                + "Pick another name or try again later."
        case let .gitFailed(message): "Git failed: \(message)"
        }
    }
}

/// A branch Fen owns for one client in one repository.
struct AgentBranch: Sendable, Equatable {
    var name: String
    var client: String
    /// Where git runs: the workspace folder.
    var directory: URL
    /// The workspace folder's path below the repository root, with a trailing slash, or empty.
    var prefix: String

    func repoPath(_ path: String) -> String {
        prefix + path
    }
}

/// What an agent sees of one file: the bytes and where they came from.
struct AgentFile: Sendable, Equatable {
    var data: Data
    /// Blob id at the commit it came from. Lets a write keep an executable file executable.
    var mode: String
    /// `true` when the branch itself holds this version, so a merge may conflict.
    var changedOnBranch: Bool
}

/// One file change in an agent commit. `data == nil` removes the path.
struct AgentFileChange: Sendable {
    var path: String
    var data: Data?
    var mode: String?
}

struct AgentCommitMessage: Sendable {
    var subject: String
    var trailers: [(String, String)]

    var body: String {
        trailers.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
}

/// The branches Fen keeps for agents, and the claims they hold (issue #93).
///
/// What Fen does in your repository, and nothing else:
/// - writes objects and moves `refs/heads/fen/*` and `refs/fen/claims/*`;
/// - never writes your index, your files or `HEAD`;
/// - fast-forwards an agent branch to `HEAD` only when everything on it is already in `HEAD`.
///
/// A commit is built in a private index file, so it never races with your own git commands. The
/// final step moves the branch with a compare-and-swap, so two writers can't both win.
final class AgentBranches: Sendable {
    static let claimLifetime: TimeInterval = 600
    private static let zero = String(repeating: "0", count: 40)
    private static let claimPrefix = "refs/fen/claims/"

    private let git: GitTool?
    private let cache = RepoCache()

    init(git: GitTool? = GitTool.locate()) {
        self.git = git
    }

    var isAvailable: Bool {
        git != nil
    }

    // MARK: - Opening

    /// The branch for `client`, or `nil` if this folder isn't in a git repository with a commit
    /// (or git isn't installed). Nothing changes yet. The branch is created by its first commit.
    func open(directory: URL, client: String) async -> AgentBranch? {
        guard let git else { return nil }
        let prefix: String
        if let known = cache.prefix(for: directory.path) {
            prefix = known
        } else {
            guard let found = try? await git.run(["rev-parse", "--show-prefix"], in: directory), found.succeeded,
                  await (try? git.run(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: directory))?.succeeded
                  == true
            else { return nil }
            // `--show-prefix` fails outside a repository, so reaching here means we are inside one.
            prefix = found.text
            cache.set(prefix, for: directory.path)
        }
        return AgentBranch(name: Self.branchName(for: client), client: client, directory: directory, prefix: prefix)
    }

    /// `fen/<name>`: lowercase letters, digits and dashes. A name that needed more than lowercasing gets a short
    /// hash, so "Claude Code" and "claude-code" don't share a branch.
    static func branchName(for client: String) -> String {
        var slug = ""
        for scalar in client.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        if slug.isEmpty {
            slug = "agent"
        }
        if slug != client.lowercased() {
            let digest = SHA256.hash(data: Data(client.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
            slug += "-" + digest
        }
        return "fen/" + slug
    }

    // MARK: - Reading

    /// The tip of the branch, or `nil` if it has no commit yet.
    func tip(of branch: AgentBranch) async throws -> String? {
        let result = try await run(["rev-parse", "--verify", "-q", "refs/heads/\(branch.name)^{commit}"], branch)
        return result.succeeded ? result.text : nil
    }

    /// The version of a file the agent should work from.
    /// - If the branch changed it, the branch version.
    /// - Otherwise the version in `HEAD`, so the agent sees what you committed since.
    /// - `nil` if neither has it. Files git doesn't track are not on any branch.
    func read(_ path: String, on branch: AgentBranch) async throws -> AgentFile? {
        try await read(path, on: branch, tip: tip(of: branch))
    }

    /// Like `read(_:on:)` from a tip you took earlier, so a write can compare against that tip.
    func read(_ path: String, on branch: AgentBranch, tip: String?) async throws -> AgentFile? {
        let repoPath = branch.repoPath(path)
        guard let head = try await headCommit(branch) else { return nil }
        let atHead = try await entry(of: repoPath, in: head, branch)
        guard let tip else { return try await file(atHead, branch, changedOnBranch: false) }
        let atTip = try await entry(of: repoPath, in: tip, branch)
        var atBase: TreeEntry?
        if let base = try await mergeBase(head, tip, branch) {
            atBase = try await entry(of: repoPath, in: base, branch)
        }
        if atTip?.id != atBase?.id {
            return try await file(atTip, branch, changedOnBranch: true)
        }
        return try await file(atHead, branch, changedOnBranch: false)
    }

    private struct TreeEntry {
        var id: String
        var mode: String
    }

    private func headCommit(_ branch: AgentBranch) async throws -> String? {
        let result = try await run(["rev-parse", "--verify", "-q", "HEAD^{commit}"], branch)
        return result.succeeded ? result.text : nil
    }

    private func mergeBase(_ first: String, _ second: String, _ branch: AgentBranch) async throws -> String? {
        let result = try await run(["merge-base", first, second], branch)
        return result.succeeded ? result.text : nil
    }

    private func entry(of repoPath: String, in commit: String, _ branch: AgentBranch) async throws -> TreeEntry? {
        let result = try await run(["ls-tree", "-z", "--full-tree", commit, "--", repoPath], branch)
        guard result.succeeded else { throw AgentBranchError.gitFailed(result.stderr) }
        // "<mode> blob <id>\t<path>\0". A directory or a link isn't a file Fen edits.
        let line = String(decoding: result.stdout, as: UTF8.self).split(separator: "\0").first.map(String.init)
        guard let line, let tab = line.firstIndex(of: "\t"), String(line[line.index(after: tab)...]) == repoPath
        else { return nil }
        let fields = line[..<tab].split(separator: " ")
        guard fields.count == 3, fields[1] == "blob", fields[0] == "100644" || fields[0] == "100755" else { return nil }
        return TreeEntry(id: String(fields[2]), mode: String(fields[0]))
    }

    private func file(_ entry: TreeEntry?, _ branch: AgentBranch, changedOnBranch: Bool) async throws -> AgentFile? {
        guard let entry else { return nil }
        let result = try await run(["cat-file", "blob", entry.id], branch)
        guard result.succeeded else { throw AgentBranchError.gitFailed(result.stderr) }
        return AgentFile(data: result.stdout, mode: entry.mode, changedOnBranch: changedOnBranch)
    }

    // MARK: - Committing

    /// Commits `changes` on top of `expectedTip` (or on top of `HEAD` for a new branch) and moves
    /// the branch there, only if it still points at `expectedTip`. Returns the new commit id.
    func commit(
        _ changes: [AgentFileChange],
        message: AgentCommitMessage,
        on branch: AgentBranch,
        expectedTip: String?
    ) async throws -> String {
        guard let parent = if let expectedTip {
            expectedTip
        } else {
            try await headCommit(branch)
        } else {
            throw AgentBranchError.gitFailed("The repository has no commit yet.")
        }
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("fen-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        try await check(run(["read-tree", parent], branch, environment: env))
        var lines = ""
        for change in changes {
            let repoPath = branch.repoPath(change.path)
            if let data = change.data {
                let blob = try await check(run(["hash-object", "-w", "--stdin"], branch, input: data)).text
                lines += "\(change.mode ?? "100644") \(blob)\t\(repoPath)\0"
            } else {
                lines += "0 \(Self.zero)\t\(repoPath)\0"
            }
        }
        // `-z`: entries end in NUL and paths are taken as is. Without it, git splits on newlines
        // and unquotes a path that starts with `"`, so one path could add a second entry.
        try await check(run(
            ["update-index", "-z", "--index-info"],
            branch,
            input: Data(lines.utf8),
            environment: env
        ))
        let tree = try await check(run(["write-tree"], branch, environment: env)).text
        let identity = [
            "GIT_AUTHOR_NAME": branch.client, "GIT_AUTHOR_EMAIL": "agent@fen.invalid",
            "GIT_COMMITTER_NAME": "Fen", "GIT_COMMITTER_EMAIL": "fen@fen.invalid",
        ]
        let commit = try await check(run(
            ["commit-tree", tree, "-p", parent, "-m", message.subject, "-m", message.body],
            branch,
            environment: identity
        )).text
        let moved = try await run(
            ["update-ref", "refs/heads/\(branch.name)", commit, expectedTip ?? Self.zero],
            branch
        )
        guard moved.succeeded else {
            // The ref moved, or the branch appeared. Either way nothing was lost: the commit is
            // an unreferenced object that git cleans up later.
            throw AgentBranchError.branchMoved(branch.name)
        }
        return commit
    }

    /// Moves a branch forward to `HEAD` when `HEAD` already contains it, which happens after you
    /// merge. Nothing on the branch is lost, so no check is needed beyond the ancestry test.
    func fastForwardIfMerged(_ branch: AgentBranch) async throws {
        guard let tip = try await tip(of: branch), let head = try await headCommit(branch), tip != head else { return }
        let ancestor = try await run(["merge-base", "--is-ancestor", tip, head], branch)
        guard ancestor.succeeded else { return }
        _ = try await run(["update-ref", "refs/heads/\(branch.name)", head, tip], branch)
    }

    // MARK: - Claims

    struct Claim: Codable, Sendable, Equatable {
        var path: String
        var client: String
        var expires: Date
    }

    /// Reserves `path` for `branch.client` until the claim expires. Advisory: it stops two agents
    /// from creating the same new file on separate branches, which git would only report at merge
    /// time. A second claim by the same client renews it. An expired claim is replaced.
    func claim(_ path: String, for branch: AgentBranch, now: Date = Date()) async throws {
        let ref = Self.claimPrefix + Self.claimKey(branch.repoPath(path))
        let mine = Claim(path: path, client: branch.client, expires: now.addingTimeInterval(Self.claimLifetime))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let blob = try await check(run(["hash-object", "-w", "--stdin"], branch, input: encoder.encode(mine))).text
        var expected = Self.zero
        for _ in 0 ..< 3 {
            let update = try await run(["update-ref", ref, blob, expected], branch)
            if update.succeeded {
                return
            }
            let current = try await run(["rev-parse", "--verify", "-q", ref], branch)
            guard current.succeeded, let existing = try await readClaim(current.text, branch) else {
                expected = Self.zero
                continue
            }
            if existing.client != branch.client, existing.expires > now {
                throw AgentBranchError.claimed(path: path, by: existing.client, until: existing.expires)
            }
            expected = current.text
        }
        throw AgentBranchError.gitFailed("Could not claim “\(path)”.")
    }

    /// Frees a claim early. A claim by another client is left alone.
    func release(_ path: String, for branch: AgentBranch) async throws {
        let ref = Self.claimPrefix + Self.claimKey(branch.repoPath(path))
        let current = try await run(["rev-parse", "--verify", "-q", ref], branch)
        guard current.succeeded, let existing = try await readClaim(current.text, branch),
              existing.client == branch.client else { return }
        _ = try await run(["update-ref", "-d", ref, current.text], branch)
    }

    /// Claims that haven't expired, for the Activity view.
    func claims(in branch: AgentBranch, now: Date = Date()) async throws -> [Claim] {
        let listing = try await run(["for-each-ref", "--format=%(objectname)", Self.claimPrefix], branch)
        var found: [Claim] = []
        for id in listing.text.split(separator: "\n") {
            if let claim = try await readClaim(String(id), branch), claim.expires > now {
                found.append(claim)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    private func readClaim(_ id: String, _ branch: AgentBranch) async throws -> Claim? {
        let result = try await run(["cat-file", "blob", id], branch)
        guard result.succeeded else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Claim.self, from: result.stdout)
    }

    private static func claimKey(_ repoPath: String) -> String {
        SHA256.hash(data: Data(repoPath.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Branches

    struct Summary: Sendable, Equatable {
        var name: String
        /// Commits on the branch that `HEAD` doesn't have yet.
        var ahead: Int
    }

    /// Every agent branch in the repository with its unmerged commit count.
    func summaries(in directory: URL) async -> [Summary] {
        guard let branch = await open(directory: directory, client: "x") else { return [] }
        guard let listing = try? await run(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads/fen/"],
            branch
        ) else { return [] }
        var result: [Summary] = []
        for name in listing.text.split(separator: "\n").map(String.init) {
            let count = try? await run(["rev-list", "--count", "HEAD..\(name)"], branch)
            result.append(Summary(name: name, ahead: count.flatMap { Int($0.text) } ?? 0))
        }
        return result
    }

    // MARK: - Running

    private func run(
        _ arguments: [String],
        _ branch: AgentBranch,
        input: Data? = nil,
        environment: [String: String] = [:]
    ) async throws -> GitTool.Output {
        guard let git else { throw AgentBranchError.gitFailed("Git isn't installed.") }
        do {
            return try await git.run(arguments, in: branch.directory, input: input, environment: environment)
        } catch {
            cache.clear()
            throw AgentBranchError.gitFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private func check(_ output: GitTool.Output) throws -> GitTool.Output {
        guard output.succeeded else {
            cache.clear()
            throw AgentBranchError.gitFailed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private final class RepoCache: @unchecked Sendable {
        private let lock = NSLock()
        private var prefixes: [String: String] = [:]

        func prefix(for directory: String) -> String? {
            lock.withLock { prefixes[directory] }
        }

        func set(_ prefix: String, for directory: String) {
            lock.withLock { prefixes[directory] = prefix }
        }

        func clear() {
            lock.withLock { prefixes.removeAll() }
        }
    }
}
