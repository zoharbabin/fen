import Foundation
import Observation

/// The sync state of one workspace, for the controls in its header (issues #60, #61).
/// There is no repository, and so nothing to show, unless the folder's `origin` is on github.com and
/// git is available. That makes it macOS only for now.
///
/// The workspace's `SyncMode` decides what Sync does. Direct-commit pulls, commits and pushes the
/// current branch. Push-as-PR puts the changes on a `fen/changes-*` branch and opens a pull request.
/// `GitHubSyncModel+Review.swift` holds the pull request side.
@MainActor @Observable
final class GitHubSyncModel {
    private(set) var repo: GitHubRepo?
    private(set) var status: GitSync.Status?
    private(set) var working: String?
    /// The last problem, in words you can act on.
    var message: String?
    var needsToken = false
    /// The pull request for the current `fen/changes-*` branch, once Fen has looked it up.
    var pullRequest: PullRequest?
    /// Notes with AI changes that a direct-commit sync leaves out, until you include them.
    var heldBack: [String] = []

    let sync: GitSync?
    let api: any GitHubAPI
    let root: () -> URL?
    let changed: () -> Void
    let inputs: Inputs
    @ObservationIgnored var autoTask: Task<Void, Never>?

    /// What the model reads from the workspace each time it syncs.
    struct Inputs {
        /// `nil` until you pick one. Sync then acts as direct-commit, without syncing on save.
        var mode: () -> SyncMode? = { nil }
        /// The workspace opted in to pushing AI changes with the rest.
        var pushesAIChanges: () -> Bool = { false }
        /// Notes with an AI change applied in place, and when the latest one was applied.
        var aiChanges: () -> [String: Date] = { [:] }
        /// How long a direct-commit workspace waits after the last file change before it backs up.
        var saveDelay: Duration = .seconds(20)
    }

    /// - Parameters:
    ///   - root: The workspace folder, or `nil` if Fen can't reach it.
    ///   - changed: Called after files on disk changed, so the workspace is listed again.
    init(
        sync: GitSync? = GitTool.locate().map { GitSync(git: $0) },
        api: any GitHubAPI = GitHubREST(),
        inputs: Inputs = Inputs(),
        root: @escaping () -> URL?,
        changed: @escaping () -> Void
    ) {
        self.sync = sync
        self.api = api
        self.inputs = inputs
        self.root = root
        self.changed = changed
    }

    var mode: SyncMode {
        inputs.mode() ?? .directCommit
    }

    var isAvailable: Bool {
        repo != nil
    }

    /// Finds the repository, then brings the folder up to date with GitHub when that is safe.
    func open() async {
        guard let sync, let root = root() else { return }
        repo = await sync.repo(at: root)
        guard repo != nil else { return }
        await refresh(fetch: false)
        await run("Pulling…") { _ = try await self.pullStep(sync, root) }
        await refreshPullRequest()
    }

    func refresh(fetch: Bool) async {
        guard let sync, let root = root(), repo != nil else { return }
        do {
            status = try await sync.status(at: root, fetch: fetch)
            let holds = mode == .directCommit && !inputs.pushesAIChanges()
            heldBack = holds ? try await heldBackPaths(sync, root) : []
        } catch {
            fail(error)
        }
    }

    func pull() async {
        guard let sync, let root = root() else { return }
        await run("Pulling…") { _ = try await self.pullStep(sync, root) }
    }

    /// Direct-commit: pulls, commits your changes in one commit, and pushes. Push-as-PR: sends them to a
    /// branch and opens a pull request. It stops at the first thing it can't do safely.
    /// - Parameter includeAIChanges: Include notes with AI changes this once, in direct-commit mode.
    func syncNow(includeAIChanges: Bool = false) async {
        guard let sync, let root = root() else { return }
        switch mode {
        case .directCommit:
            await run("Backing up…") { try await self.backUp(sync, root, includeAIChanges: includeAIChanges) }
        case .pushAsPR:
            await run("Syncing…") { try await self.sendForReview(sync, root) }
        }
    }

    func saveToken(_ text: String) -> Bool {
        guard let repo, let sync else { return false }
        do {
            try sync.secrets.write(GitHubToken.validate(text), account: repo.tokenAccount)
            needsToken = false
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    // MARK: - Steps

    /// `true` when the folder can go on to commit and push.
    func pullStep(_ sync: GitSync, _ root: URL) async throws -> Bool {
        switch try await sync.pull(at: root) {
        case .upToDate:
            return true
        case .updated:
            changed()
            return true
        case .diverged:
            message = "This Mac and GitHub both have new commits. Fen doesn't merge them yet. Merge with git, then sync again."
            return false
        case let .blocked(reason):
            message = "Fen didn't pull, to keep your edits: \(reason)"
            return false
        }
    }

    func run(_ label: String, _ work: () async throws -> Void) async {
        guard working == nil else { return }
        working = label
        message = nil
        defer { working = nil }
        do {
            try await work()
        } catch {
            fail(error)
        }
        await refresh(fetch: false)
    }

    func fail(_ error: Error) {
        if case GitSync.SyncError.authFailed = error {
            needsToken = true
        }
        message = error.localizedDescription
    }
}
