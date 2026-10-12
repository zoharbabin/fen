import Foundation

/// Clone, pull and push for a git-backed workspace (issue #60). It runs the `git` program through
/// `GitTool`, so it is macOS only for now. A workspace is a plain git work tree: Fen adds no file to
/// it, so `git log` is the history and a sync commit holds only the notes you changed.
///
/// The token never goes on a command line, in the repository's config or in a URL. It reaches git
/// through its environment as an HTTP header for `https://github.com/` only, so a redirect to another
/// host doesn't carry it.
struct GitSync: Sendable {
    enum SyncError: Error, Equatable, LocalizedError {
        case gitMissing
        case notARepository
        case folderNotEmpty
        case authFailed(String)
        /// GitHub turned the push down for a reason of its own, such as a protected branch. Git's reason.
        case pushRefused(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .gitMissing:
                "Fen can't find git on this Mac. Install the Xcode command line tools."
            case .notARepository:
                "This folder isn't a git repository."
            case .folderNotEmpty:
                "The folder isn't empty."
            case let .authFailed(repo):
                "GitHub refused the token for \(repo). Check that it can read and write this repository's contents."
            case let .pushRefused(reason):
                "GitHub didn't accept the push: \(reason)"
            case let .failed(message):
                message
            }
        }
    }

    struct Status: Equatable {
        var branch: String?
        /// `origin/<branch>` when the branch tracks one.
        var upstream: String?
        /// Local commits the remote doesn't have.
        var ahead = 0
        /// Remote commits you don't have.
        var behind = 0
        /// Files with changes not yet committed.
        var changedFiles = 0

        var isClean: Bool {
            changedFiles == 0 && ahead == 0 && behind == 0
        }

        var text: String {
            guard let branch else { return "No branch" }
            guard upstream != nil else { return "\(branch) has no remote branch" }
            var parts = [branch]
            if changedFiles > 0 {
                parts.append("\(changedFiles) changed")
            }
            if ahead > 0 {
                parts.append("\(ahead) to push")
            }
            if behind > 0 {
                parts.append("\(behind) to pull")
            }
            if parts.count == 1 {
                parts.append("up to date")
            }
            return parts.joined(separator: " · ")
        }
    }

    enum PullResult: Equatable {
        case upToDate
        case updated(commits: Int)
        /// Both sides have new commits. `merge(at:)` combines them.
        case diverged
        /// A fast-forward would overwrite changes you haven't committed.
        case blocked(String)
    }

    enum PushResult: Equatable {
        case nothingToPush
        case pushed(commits: Int)
        /// The remote has commits you don't. Pull first.
        case rejected
    }

    let git: GitTool
    let secrets: any SecretStore
    /// Fen cloned this folder (`WorkspaceSettings.clonedByFen`), so `refusal(at:)` skips the settings check.
    var clonedByFen = false

    init(git: GitTool, secrets: any SecretStore = KeychainSecretStore(service: GitHubToken.service)) {
        self.git = git
        self.secrets = secrets
    }

    // MARK: - Clone

    /// Clones into `folder`, which must exist and be empty. On failure the folder is left empty again.
    func clone(_ remote: URL, into folder: URL, token: String?) async throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard contents.isEmpty else { throw SyncError.folderNotEmpty }
        let out = try await git.run(
            ["clone", "--quiet", "--", remote.absoluteString, "."],
            in: folder,
            environment: Self.environment(for: remote, token: token)
        )
        guard out.succeeded else {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(item))
            }
            throw error(from: out, repo: GitHubRepo.parse(remote.absoluteString), token: token)
        }
    }

    // MARK: - Status

    /// The `origin` remote when it is on github.com.
    func repo(at root: URL) async -> GitHubRepo? {
        guard let out = try? await git.run(["config", "--get", "remote.origin.url"], in: root), out.succeeded else {
            return nil
        }
        return GitHubRepo.parse(out.text)
    }

    func token(for repo: GitHubRepo) -> String? {
        (try? secrets.read(account: repo.tokenAccount)) ?? nil
    }

    /// `fetch` asks the remote first, so ahead and behind are current.
    func status(at root: URL, fetch: Bool = false) async throws -> Status {
        if fetch {
            try await fetchRemote(at: root)
        }
        var status = Status()
        let head = try await run(["rev-parse", "--abbrev-ref", "HEAD"], at: root, allowFailure: true)
        if head.succeeded, head.text != "HEAD" {
            status.branch = head.text
        }
        let upstream = try await run(["rev-parse", "--abbrev-ref", "@{u}"], at: root, allowFailure: true)
        if upstream.succeeded {
            status.upstream = upstream.text
            let counts = try await run(["rev-list", "--left-right", "--count", "HEAD...@{u}"], at: root)
            let numbers = counts.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if numbers.count == 2 {
                status.ahead = numbers[0]
                status.behind = numbers[1]
            }
        }
        status.changedFiles = try await changedPaths(at: root).count
        return status
    }

    // MARK: - Pull

    /// Fast-forwards to the remote branch. It never creates a merge commit and never changes a file
    /// you have edited.
    func pull(at root: URL) async throws -> PullResult {
        try await fetchRemote(at: root)
        let status = try await status(at: root)
        guard status.upstream != nil else { throw SyncError.failed("This branch has no remote branch to pull from.") }
        if status.behind == 0 {
            return .upToDate
        }
        if status.ahead > 0 {
            return .diverged
        }
        let merge = try await run(["merge", "--ff-only", "--quiet", "@{u}"], at: root, allowFailure: true)
        guard merge.succeeded else {
            return .blocked(Self.firstLine(merge.stderr, fallback: "Your changes are in the way."))
        }
        return .updated(commits: status.behind)
    }

    // MARK: - Commit and push

    /// Commits the changed notes in one commit. Files that look like secrets are never added, and neither
    /// are the `held` paths. Returns the number of files committed, 0 when nothing changed.
    @discardableResult
    func commitChanges(at root: URL, message: String? = nil, held: Set<String> = []) async throws -> Int {
        let paths = try await changedPaths(at: root)
            .filter { !held.contains($0) && !FileEligibility.looksSecret(fileName: ($0 as NSString).lastPathComponent) }
        guard !paths.isEmpty else { return 0 }
        let list = Data(paths.joined(separator: "\0").utf8) + Data([0])
        let add = try await git.run(
            ["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"],
            in: root,
            input: list
        )
        guard add.succeeded else { throw SyncError.failed(Self.firstLine(add.stderr, fallback: "git add failed.")) }
        let staged = try await run(["diff", "--cached", "--name-only"], at: root)
        guard !staged.text.isEmpty else { return 0 }
        var arguments = await Self.identity(at: root, using: self)
        // `--only` with the list keeps a path you staged yourself, or one held back, out of this commit.
        arguments += [
            "commit", "--quiet", "--only", "-m", message ?? Self.message(for: paths),
            "--pathspec-from-file=-", "--pathspec-file-nul",
        ]
        let commit = try await git.run(arguments, in: root, input: list)
        guard commit.succeeded else { throw SyncError.failed(Self.firstLine(
            commit.stderr,
            fallback: "git commit failed."
        )) }
        return paths.count
    }

    /// Pushes the current branch. It never forces.
    func push(at root: URL) async throws -> PushResult {
        let status = try await status(at: root)
        guard let branch = status.branch else { throw SyncError.failed("There's no branch to push.") }
        if status.upstream != nil, status.ahead == 0 {
            return .nothingToPush
        }
        let out = try await git.run(
            ["push", "--quiet", "--set-upstream", "origin", "HEAD:refs/heads/\(branch)"],
            in: root,
            environment: environment(at: root)
        )
        guard out.succeeded else {
            // Only "you are behind" means pull first. A protected branch or a rule says `[remote rejected]`.
            if out.stderr.contains("[rejected]"),
               out.stderr.contains("non-fast-forward") || out.stderr.contains("fetch first") {
                return .rejected
            }
            let repo = await repo(at: root)
            throw error(from: out, repo: repo, token: repo.flatMap(token(for:)))
        }
        // Without a tracking branch the count is the whole history, so report what was pushed.
        return .pushed(commits: max(status.ahead, 1))
    }

    // MARK: - Helpers

    private func fetchRemote(at root: URL) async throws {
        let out = try await git.run(
            ["fetch", "--quiet", "--prune", "origin"],
            in: root,
            environment: environment(at: root)
        )
        guard out.succeeded else {
            let repo = await repo(at: root)
            throw error(from: out, repo: repo, token: repo.flatMap(token(for:)))
        }
    }

    /// The token goes in only when `refusal(at:)` passes, so a folder's own git settings never see it.
    func environment(at root: URL) async -> [String: String] {
        guard let repo = await repo(at: root), await refusal(at: root) == nil else {
            return Self.environment(for: nil, token: nil)
        }
        return Self.environment(for: repo.cloneURL, token: token(for: repo))
    }

    /// Paths with changes that aren't committed, including new files git doesn't ignore.
    func changedPaths(at root: URL) async throws -> [String] {
        let out = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"], at: root)
        return out.stdout.split(separator: 0).compactMap { entry -> String? in
            let line = String(decoding: entry, as: UTF8.self)
            return line.count > 3 ? String(line.dropFirst(3)) : nil
        }
    }

    @discardableResult
    func run(_ arguments: [String], at root: URL, allowFailure: Bool = false) async throws -> GitTool.Output {
        let out = try await git.run(arguments, in: root)
        if !out.succeeded, !allowFailure {
            if out.stderr.contains("not a git repository") {
                throw SyncError.notARepository
            }
            throw SyncError.failed(Self.firstLine(out.stderr, fallback: "git \(arguments.first ?? "") failed."))
        }
        return out
    }

    /// Git settings in the environment. `credential.helper` is cleared so no stored login is used and the
    /// system keychain never prompts. The header applies to github.com over https only.
    static func environment(for remote: URL?, token: String?) -> [String: String] {
        var settings = [("credential.helper", "")]
        if let token, remote?.scheme == "https", remote?.host == "github.com" {
            settings.append(("http.https://github.com/.extraheader", "Authorization: Basic \(basicCredential(token))"))
        }
        var env = ["GIT_CONFIG_COUNT": "\(settings.count)"]
        for (index, setting) in settings.enumerated() {
            env["GIT_CONFIG_KEY_\(index)"] = setting.0
            env["GIT_CONFIG_VALUE_\(index)"] = setting.1
        }
        return env
    }

    func error(from out: GitTool.Output, repo: GitHubRepo?, token: String?) -> SyncError {
        var text = out.stderr
        if let token, !token.isEmpty {
            text = text.replacingOccurrences(of: token, with: "***")
                .replacingOccurrences(of: Self.basicCredential(token), with: "***")
        }
        let denied = [
            "Authentication failed", "could not read Username", "Permission denied", "Permission to",
            "returned error: 401", "returned error: 403", "Repository not found", "' not found",
        ]
        if denied.contains(where: text.contains) {
            return .authFailed(repo?.title ?? "this repository")
        }
        if ["[remote rejected]", "declined", "repository rule violations"].contains(where: text.contains) {
            return .pushRefused(Self.refusalReason(text))
        }
        return .failed(Self.firstLine(text, fallback: "git failed."))
    }

    /// The value after `Authorization: Basic`.
    static func basicCredential(_ token: String) -> String {
        Data("x-access-token:\(token)".utf8).base64EncodedString()
    }

    /// GitHub's own words for a refused push: its `remote:` lines, or else the reason git gives in
    /// brackets after `[remote rejected]`.
    static func refusalReason(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let remote = lines.filter { $0.hasPrefix("remote:") }.map { line in
            let rest = line.dropFirst("remote:".count).trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix("error:") ? rest.dropFirst("error:".count).trimmingCharacters(in: .whitespaces) : rest
        }.filter { !$0.isEmpty }
        if !remote.isEmpty {
            return remote.joined(separator: " ")
        }
        if let line = lines.first(where: { $0.contains("[remote rejected]") }), line.hasSuffix(")"),
           let open = line.lastIndex(of: "(") {
            return String(line[line.index(after: open) ..< line.index(before: line.endIndex)])
        }
        return firstLine(text, fallback: "GitHub gave no reason.")
    }

    static func firstLine(_ text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? fallback
    }

    static func message(for paths: [String]) -> String {
        let names = paths.prefix(3).map { ($0 as NSString).lastPathComponent }
        return paths.count <= 3 ? "Update " + names.joined(separator: ", ") : "Update \(paths.count) notes"
    }
}
