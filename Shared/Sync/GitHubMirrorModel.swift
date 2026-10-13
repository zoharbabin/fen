import Foundation
import Observation

/// The sync state of one GitHub workspace on iOS, for the controls in its header (issue #60).
/// iOS can't run git, so a workspace cloned there is a `GitHubMirror`. Nothing syncs by itself: you
/// pull, back up, and settle conflicts yourself, because iOS may suspend the app at any time.
@MainActor @Observable
final class GitHubMirrorModel {
    private(set) var state: MirrorState?
    private(set) var working: String?
    /// Notes that differ from the last sync.
    private(set) var pending: [String] = []
    /// Notes with AI changes that a backup leaves out, until you include them.
    private(set) var heldBack: [String] = []
    /// The last problem, in words you can act on.
    var message: String?
    var needsToken = false

    let mirror: GitHubMirror
    let id: UUID
    let inputs: Inputs
    let root: () -> URL?
    let changed: () -> Void

    struct Inputs {
        /// The workspace opted in to pushing AI changes with the rest.
        var pushesAIChanges: () -> Bool = { false }
        /// Notes with an AI change applied in place, and when the latest one was applied.
        var aiChanges: () -> [String: Date] = { [:] }
    }

    init(
        mirror: GitHubMirror = GitHubMirror(),
        id: UUID,
        inputs: Inputs = Inputs(),
        root: @escaping () -> URL?,
        changed: @escaping () -> Void
    ) {
        self.mirror = mirror
        self.id = id
        self.inputs = inputs
        self.root = root
        self.changed = changed
        state = mirror.load(id: id)
    }

    /// `false` for a workspace that isn't a copy of a GitHub repository.
    var isMirror: Bool {
        state != nil
    }

    var repo: GitHubRepo? {
        state?.repo
    }

    var conflicts: [String] {
        state?.conflicts.keys.sorted() ?? []
    }

    /// The one line of state in the header.
    var summary: String {
        let title = repo?.title ?? "GitHub"
        if !conflicts.isEmpty {
            return conflicts.count == 1
                ? "1 note has a conflict to fix"
                : "\(conflicts.count) notes have conflicts to fix"
        }
        let waiting = max(pending.count - heldBack.count, 0)
        var parts: [String] = []
        if waiting > 0 {
            parts.append(waiting == 1 ? "1 note not backed up" : "\(waiting) notes not backed up")
        }
        if !heldBack.isEmpty {
            parts
                .append(heldBack.count == 1 ? "1 AI change waits for you" : "\(heldBack.count) AI changes wait for you")
        }
        return parts.isEmpty ? "Backed up to \(title)" : parts.joined(separator: " · ")
    }

    /// Brings the folder up to date when you open the workspace.
    func open() async {
        await pull()
    }

    func pull() async {
        await run("Pulling…") { state, root, token in
            let (next, report) = try await self.mirror.pull(state, root: root, token: token)
            if report.updated > 0 {
                self.changed()
            }
            return next
        }
    }

    /// Pulls, then sends your changes as one commit. It stops at the first conflict.
    /// - Parameter includeAIChanges: Include notes with AI changes this once.
    func syncNow(includeAIChanges: Bool = false) async {
        guard let repo, mirror.token(for: repo) != nil else {
            needsToken = true
            message = "Add a token to back up to GitHub."
            return
        }
        let held = includeAIChanges ? [] : Set(heldBack)
        await run("Backing up…") { state, root, token in
            guard let token else { throw GitSync.SyncError.authFailed(repo.title) }
            // Pull on its own first, so conflicts are saved and listed even though nothing is sent.
            let (pulled, report) = try await self.mirror.pull(state, root: root, token: token)
            if report.updated > 0 {
                self.changed()
            }
            guard pulled.conflicts.isEmpty else {
                self.message = MirrorError.conflicts(pulled.conflicts.count).localizedDescription
                return pulled
            }
            let (next, _) = try await self.mirror.push(pulled, root: root, token: token, held: held)
            self.changed()
            return next
        }
    }

    func resolve(_ path: String, keepMine: Bool) async {
        await run("Settling…") { state, root, token in
            let next = try await self.mirror.resolve(path, keepMine: keepMine, in: state, root: root, token: token)
            self.changed()
            return next
        }
    }

    func refreshPending() async {
        guard let state, let root = root() else { return }
        let mirror = mirror
        pending = await Task.detached { mirror.pendingChanges(state, root: root) }.value
        let cutoff = state.syncedAt
        let ai = inputs.aiChanges()
        heldBack = inputs.pushesAIChanges() ? [] : pending.filter { (ai[$0] ?? .distantPast) > cutoff }
    }

    func saveToken(_ text: String) -> Bool {
        guard let repo else { return false }
        do {
            try mirror.secrets.write(GitHubToken.validate(text), account: repo.tokenAccount)
            needsToken = false
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    // MARK: - Steps

    private func run(
        _ label: String,
        _ work: (MirrorState, URL, String?) async throws -> MirrorState
    ) async {
        guard working == nil, let current = state, let repo = current.repo, let root = root() else { return }
        working = label
        message = nil
        defer { working = nil }
        do {
            let next = try await work(current, root, mirror.token(for: repo))
            state = next
            try mirror.save(next, id: id)
        } catch {
            fail(error)
        }
        await refreshPending()
    }

    private func fail(_ error: Error) {
        if case GitSync.SyncError.authFailed = error {
            needsToken = true
        }
        message = error.localizedDescription
    }
}
