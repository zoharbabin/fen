import Foundation
import Observation

/// The sync state of one workspace, for the controls in its header (issue #60).
/// There is no repository, and so nothing to show, unless the folder's `origin` is on github.com and
/// git is available. That makes it macOS only for now.
@MainActor @Observable
final class GitHubSyncModel {
    private(set) var repo: GitHubRepo?
    private(set) var status: GitSync.Status?
    private(set) var working: String?
    /// The last problem, in words you can act on.
    private(set) var message: String?
    private(set) var needsToken = false

    private let sync: GitSync?
    private let root: () -> URL?
    private let changed: () -> Void

    /// - Parameters:
    ///   - root: The workspace folder, or `nil` if Fen can't reach it.
    ///   - changed: Called after files on disk changed, so the workspace is listed again.
    init(
        sync: GitSync? = GitTool.locate().map { GitSync(git: $0) },
        root: @escaping () -> URL?,
        changed: @escaping () -> Void
    ) {
        self.sync = sync
        self.root = root
        self.changed = changed
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
    }

    func refresh(fetch: Bool) async {
        guard let sync, let root = root(), repo != nil else { return }
        do {
            status = try await sync.status(at: root, fetch: fetch)
        } catch {
            fail(error)
        }
    }

    func pull() async {
        guard let sync, let root = root() else { return }
        await run("Pulling…") { _ = try await self.pullStep(sync, root) }
    }

    /// Pulls, commits your changes in one commit, and pushes. It stops at the first thing it can't do safely.
    func syncNow() async {
        guard let sync, let root = root() else { return }
        await run("Syncing…") {
            guard try await self.pullStep(sync, root) else { return }
            try await sync.commitChanges(at: root)
            switch try await sync.push(at: root) {
            case .rejected: self.message = "GitHub has new commits. Pull first."
            case .nothingToPush, .pushed: break
            }
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
    private func pullStep(_ sync: GitSync, _ root: URL) async throws -> Bool {
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

    private func run(_ label: String, _ work: () async throws -> Void) async {
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

    private func fail(_ error: Error) {
        if case GitSync.SyncError.authFailed = error {
            needsToken = true
        }
        message = error.localizedDescription
    }
}
