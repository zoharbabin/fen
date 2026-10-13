import CryptoKit
import Foundation

enum MirrorError: Error, Equatable, LocalizedError {
    /// GitHub cut the list of files short, so the repository is too big to mirror.
    case treeTooLarge
    /// The branch moved while Fen was sending a commit.
    case branchMoved
    case conflicts(Int)
    case unsafePath(String)
    case notAMirror

    var errorDescription: String? {
        switch self {
        case .treeTooLarge:
            "This repository has too many files for Fen to copy to this device."
        case .branchMoved:
            "GitHub has new changes. Back up again."
        case let .conflicts(count):
            count == 1
                ? "1 note changed here and on GitHub. Choose which one to keep first."
                : "\(count) notes changed here and on GitHub. Choose which one to keep first."
        case let .unsafePath(path):
            "GitHub listed a file path Fen won't use: \(path)"
        case .notAMirror:
            "This workspace isn't a copy of a GitHub repository."
        }
    }
}

/// What a GitHub workspace on iOS last synced (issue #60). It is the base of a three-way compare: the
/// file as it was at the last sync, the file now on this device, and the file now on GitHub.
struct MirrorState: Codable, Equatable, Sendable {
    var owner: String
    var name: String
    var branch: String
    var commit: String
    var tree: String
    /// Path to git's hash of the file at the last sync.
    var files: [String: String]
    /// Notes that changed here and on GitHub. The value is GitHub's hash, empty when GitHub deleted the note.
    var conflicts: [String: String] = [:]
    var syncedAt: Date

    var repo: GitHubRepo? {
        GitHubRepo.parse("\(owner)/\(name)")
    }
}

struct PullReport: Equatable, Sendable {
    /// Files written or deleted here to match GitHub.
    var updated = 0
}

/// A GitHub repository kept as plain files in a folder, with no git (issue #60). iOS can't run git, so this
/// copies the repository's files through the GitHub API and sends edits back as one commit.
///
/// It never overwrites or deletes a file you changed. A note that changed on both sides becomes a
/// conflict, and nothing happens to it until you choose. A sync never forces: if the branch moved, it
/// pulls and tries again. Fen adds no file to the folder; the sync state lives in `FenHome`.
struct GitHubMirror: Sendable {
    /// Larger files stay on GitHub.
    static let maxFileSize = 2_000_000
    private static let parallelDownloads = 6

    var remote: any GitHubRemote = GitHubREST()
    var secrets: any SecretStore = KeychainSecretStore(service: GitHubToken.service)
    var now: @Sendable () -> Date = { Date() }
    let home: FenHome

    init(home: FenHome = .standard) {
        self.home = home
    }

    func token(for repo: GitHubRepo) -> String? {
        (try? secrets.read(account: repo.tokenAccount)) ?? nil
    }

    // MARK: - State

    func load(id: UUID) -> MirrorState? {
        guard let data = try? Data(contentsOf: home.mirrorFile(id: id)) else { return nil }
        return try? JSONDecoder.iso8601.decode(MirrorState.self, from: data)
    }

    func save(_ state: MirrorState, id: UUID) throws {
        try FileManager.default.createDirectory(
            at: home.workspaceDirectory(id: id),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: home.mirrorFile(id: id), options: .atomic)
    }

    // MARK: - Clone

    /// Copies the default branch into `root`, which must be an empty folder.
    func download(_ repo: GitHubRepo, token: String?, into root: URL) async throws -> MirrorState {
        let head = try await remote.head(of: repo, token: token)
        let files = try await remote.files(in: head.tree, of: repo, token: token).filter(Self.isWanted)
        try await write(files, of: repo, token: token, into: root)
        return MirrorState(
            owner: repo.owner,
            name: repo.name,
            branch: head.branch,
            commit: head.commit,
            tree: head.tree,
            files: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.sha) }),
            syncedAt: now()
        )
    }

    // MARK: - Pull

    /// Brings the folder up to date with GitHub. A file you didn't change takes GitHub's version. A file
    /// you changed is left alone, and one GitHub changed too becomes a conflict.
    func pull(_ state: MirrorState, root: URL, token: String?) async throws -> (MirrorState, PullReport) {
        guard let repo = state.repo else { throw MirrorError.notAMirror }
        let head = try await remote.head(of: repo, token: token)
        guard head.commit != state.commit else { return (state, PullReport()) }
        let listed = try await remote.files(in: head.tree, of: repo, token: token).filter(Self.isWanted)
        let theirs = Dictionary(uniqueKeysWithValues: listed.map { ($0.path, $0) })
        let (compared, plan) = compare(state, theirs: theirs, mine: snapshot(of: root))
        var next = compared
        let updated = try await apply(plan, to: &next, from: state, token: token, root: root)
        next.branch = head.branch
        next.commit = head.commit
        next.tree = head.tree
        next.syncedAt = now()
        return (next, PullReport(updated: updated))
    }

    /// Files to write or delete here, found by comparing the last sync, this device and GitHub.
    private struct Plan {
        var download: [RemoteFile] = []
        var delete: [String] = []
    }

    private func compare(
        _ state: MirrorState,
        theirs: [String: RemoteFile],
        mine: [String: String]
    ) -> (MirrorState, Plan) {
        var next = state
        var plan = Plan()
        for path in Set(state.files.keys).union(theirs.keys) {
            let base = state.files[path]
            let remoteSHA = theirs[path]?.sha
            let local = mine[path]
            if remoteSHA == base {
                next.conflicts[path] = nil
            } else if local == remoteSHA {
                next.files[path] = remoteSHA
                next.conflicts[path] = nil
            } else if local == base {
                if let file = theirs[path] {
                    plan.download.append(file)
                } else {
                    plan.delete.append(path)
                }
            } else {
                next.conflicts[path] = remoteSHA ?? ""
            }
        }
        return (next, plan)
    }

    /// Returns the number of files written or deleted. A file you edit while this runs is checked again
    /// just before it is replaced, and becomes a conflict if it changed.
    private func apply(
        _ plan: Plan,
        to next: inout MirrorState,
        from state: MirrorState,
        token: String?,
        root: URL
    ) async throws -> Int {
        guard let repo = state.repo else { throw MirrorError.notAMirror }
        var updated = 0
        for file in plan.download {
            if currentSHA(of: file.path, in: root) == state.files[file.path] {
                try await write([file], of: repo, token: token, into: root)
                next.files[file.path] = file.sha
                next.conflicts[file.path] = nil
                updated += 1
            } else {
                next.conflicts[file.path] = file.sha
            }
        }
        for path in plan.delete {
            if currentSHA(of: path, in: root) == state.files[path] {
                try FileManager.default.removeItem(at: url(for: path, in: root))
                next.files[path] = nil
                next.conflicts[path] = nil
                updated += 1
            } else {
                next.conflicts[path] = ""
            }
        }
        return updated
    }

    // MARK: - Push

    /// Sends the notes you changed to GitHub as one commit on top of the newest one. `held` paths stay
    /// here. Returns the number of files sent, 0 when there was nothing to send.
    func push(
        _ state: MirrorState,
        root: URL,
        token: String,
        held: Set<String> = [],
        message: String? = nil
    ) async throws -> (MirrorState, Int) {
        var state = state
        guard let repo = state.repo else { throw MirrorError.notAMirror }
        for _ in 0 ..< 2 {
            state = try await pull(state, root: root, token: token).0
            guard state.conflicts.isEmpty else { throw MirrorError.conflicts(state.conflicts.count) }
            let mine = snapshot(of: root)
            let changed = Set(state.files.keys).union(mine.keys)
                .filter { !held.contains($0) && mine[$0] != state.files[$0] && !isTooBig(mine[$0]) }
                .sorted()
            guard !changed.isEmpty else { return (state, 0) }
            var changes: [String: Data?] = [:]
            for path in changed {
                changes[path] = mine[path] == nil ? .some(nil) : try Data(contentsOf: url(for: path, in: root))
            }
            let head = RemoteHead(branch: state.branch, commit: state.commit, tree: state.tree)
            do {
                let sent = try await remote.commit(
                    changes,
                    message: message ?? GitSync.message(for: changed),
                    onTopOf: head,
                    in: repo,
                    token: token
                )
                state.commit = sent.commit
                state.tree = sent.tree
                for path in changed {
                    state.files[path] = mine[path]
                }
                state.syncedAt = now()
                return (state, changed.count)
            } catch MirrorError.branchMoved {
                continue
            }
        }
        throw MirrorError.branchMoved
    }

    // MARK: - Conflicts

    /// Settles one conflicted note. `keepMine` makes your version the one the next backup sends. Otherwise
    /// GitHub's version replaces yours, or your note is deleted if GitHub deleted it.
    func resolve(
        _ path: String,
        keepMine: Bool,
        in state: MirrorState,
        root: URL,
        token: String?
    ) async throws -> MirrorState {
        guard let repo = state.repo, let theirs = state.conflicts[path] else { return state }
        var next = state
        let remoteSHA = theirs.isEmpty ? nil : theirs
        if !keepMine {
            if let remoteSHA {
                try await write([RemoteFile(path: path, sha: remoteSHA, size: 0)], of: repo, token: token, into: root)
            } else {
                let location = try url(for: path, in: root)
                if FileManager.default.fileExists(atPath: location.path) {
                    try FileManager.default.removeItem(at: location)
                }
            }
        }
        next.files[path] = remoteSHA
        next.conflicts[path] = nil
        return next
    }

    // MARK: - Local files

    /// How many notes differ from the last sync, for the status line.
    func pendingChanges(_ state: MirrorState, root: URL) -> [String] {
        let mine = snapshot(of: root)
        return Set(state.files.keys).union(mine.keys)
            .filter { mine[$0] != state.files[$0] && !isTooBig(mine[$0]) }
            .sorted()
    }

    /// Git's hash of every file that Fen syncs, by path. A file over `maxFileSize` is listed as too big.
    func snapshot(of root: URL) -> [String: String] {
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return result
        }
        let prefix = (PathGate.canonicalURL(of: root) ?? root).path + "/"
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let path = String((PathGate.canonicalURL(of: file) ?? file).path.dropFirst(prefix.count))
            guard Self.isSyncable(path) else { continue }
            if (values.fileSize ?? 0) > Self.maxFileSize {
                result[path] = Self.tooBig
            } else if let data = try? Data(contentsOf: file) {
                result[path] = Self.blobSHA(of: data)
            }
        }
        return result
    }

    private static let tooBig = "too-big"

    private func isTooBig(_ sha: String?) -> Bool {
        sha == Self.tooBig
    }

    private func currentSHA(of path: String, in root: URL) -> String? {
        guard let location = try? url(for: path, in: root), let data = try? Data(contentsOf: location) else {
            return nil
        }
        return Self.blobSHA(of: data)
    }

    /// The location of `path` in `root`. A path from GitHub that leaves the folder, or reaches `.git`, throws.
    private func url(for path: String, in root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard Self.isSyncable(path), !path.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }),
              let location = PathGate.resolve(relativePath: path, in: root)
        else { throw MirrorError.unsafePath(path) }
        return location
    }

    private func write(_ files: [RemoteFile], of repo: GitHubRepo, token: String?, into root: URL) async throws {
        let locations = try files.map { try (file: $0, location: url(for: $0.path, in: root)) }
        for start in stride(from: 0, to: locations.count, by: Self.parallelDownloads) {
            let batch = locations[start ..< min(start + Self.parallelDownloads, locations.count)]
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (file, location) in batch {
                    group.addTask {
                        let data = try await remote.content(of: file, in: repo, token: token)
                        try FileManager.default.createDirectory(
                            at: location.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try data.write(to: location, options: .atomic)
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    // MARK: - Rules

    /// Files Fen copies from GitHub: the ones it would also send back.
    private static func isWanted(_ file: RemoteFile) -> Bool {
        isSyncable(file.path) && file.size <= maxFileSize
    }

    /// Never `.git`, the system's `.DS_Store`, or a file that looks like it holds a secret.
    static func isSyncable(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        guard let name = parts.last, !parts.contains(".git"), name != ".ds_store" else { return false }
        return !FileEligibility.looksSecret(fileName: name)
    }

    /// Git's object id for a file: SHA-1 of `blob <size>`, a zero byte, then the content.
    static func blobSHA(of data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
