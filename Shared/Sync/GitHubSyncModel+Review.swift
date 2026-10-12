import Foundation

/// The two sync modes (issue #61). Direct-commit backs up to the current branch. Push-as-PR keeps your
/// edits on a `fen/changes-*` branch and opens a pull request for each set of changes.
extension GitHubSyncModel {
    // MARK: - Direct-commit

    /// Pulls, commits and pushes. Notes with an AI change stay out unless the workspace opted in.
    /// When GitHub and this Mac both changed, the two are merged. A note both sides changed keeps both
    /// versions as conflict markers, and nothing is pushed until you edit them away (issue #62).
    func backUp(_ sync: GitSync, _ root: URL, includeAIChanges: Bool) async throws {
        guard try await leaveReviewBranch(sync, root) else { return }
        if let waiting = try await sync.finishMerge(at: root) {
            guard report(waiting) else { return changed() }
            changed()
        }
        let held = includeAIChanges || inputs.pushesAIChanges() ? [] : try await heldBackPaths(sync, root)
        guard try await pullOrMerge(sync, root, held: Set(held)) else { return }
        try await sync.commitChanges(at: root, held: Set(held))
        switch try await sync.push(at: root) {
        case .rejected: message = "GitHub has new commits. Back up again."
        case .nothingToPush, .pushed: break
        }
    }

    /// Fast-forwards when it can. When both sides have new commits, or your edits are in the way, it
    /// commits your changes and merges. `true` when the folder can go on to commit and push.
    private func pullOrMerge(_ sync: GitSync, _ root: URL, held: Set<String>) async throws -> Bool {
        switch try await sync.pull(at: root) {
        case .upToDate:
            return true
        case .updated:
            changed()
            return true
        case .diverged, .blocked:
            try await sync.commitChanges(at: root, held: held)
            let result = try await sync.merge(at: root)
            changed()
            return report(result)
        }
    }

    /// Says what a merge left for you. `true` when it is finished.
    private func report(_ result: GitSync.MergeResult) -> Bool {
        switch result {
        case let .merged(copies):
            conflicts = []
            if !copies.isEmpty {
                message = "GitHub's version of a note that can't show conflicts is saved as \(copies.joined(separator: ", ")). Yours stayed in place."
            }
            return true
        case let .conflicts(notes):
            conflicts = notes
            message = Self.conflictMessage(notes)
            return false
        case let .blocked(reason):
            message = "Fen didn't merge, to keep your edits: \(reason)"
            return false
        }
    }

    static func conflictMessage(_ notes: [String]) -> String {
        let names = notes.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        let more = notes.count > 3 ? " and \(notes.count - 3) more" : ""
        return "\(notes.count == 1 ? "1 note has" : "\(notes.count) notes have") conflicts: \(names)\(more). "
            + "Both versions are in the note, between <<<<<<< and >>>>>>>. Edit them, then back up again."
    }

    /// Notes with uncommitted changes where an AI change was applied after the note was last committed.
    func heldBackPaths(_ sync: GitSync, _ root: URL) async throws -> [String] {
        let applied = inputs.aiChanges()
        guard !applied.isEmpty else { return [] }
        let changedFiles = try await sync.changedFiles(at: root).filter { applied[$0] != nil }
        let committed = try await sync.lastCommitDates(of: changedFiles, at: root)
        return changedFiles.filter { applied[$0, default: .distantPast] > committed[$0, default: .distantPast] }
            .sorted()
    }

    /// A workspace switched from push-as-PR may sit on a `fen/changes-*` branch. Direct-commit leaves
    /// that branch alone while its pull request is open or you have edits on it, and says so.
    /// - Returns: `true` when the folder is on a branch direct-commit can use.
    private func leaveReviewBranch(_ sync: GitSync, _ root: URL) async throws -> Bool {
        let status = try await sync.status(at: root)
        guard GitSync.isWorkingBranch(status.branch), let branch = status.branch, let repo else { return true }
        let pull = try await api.pullRequest(head: branch, in: repo, token: sync.token(for: repo))
        pullRequest = pull
        if pull?.state == .open {
            message = "Your changes wait in pull request #\(pull?.number ?? 0). Merge or close it on GitHub, then back up again."
            return false
        }
        // Once merged, the default branch holds everything on this one, so your edits can move along.
        let merged = pull?.state == .merged
        // A branch that tracks nothing reports 0 ahead, so count the commits GitHub doesn't have.
        let unpushed = status.upstream == nil && !merged ? try await sync.unpushedCommits(at: root) : status.ahead
        guard unpushed == 0, status.changedFiles == 0 || merged else {
            message = "This folder is on the review branch \(branch), and it has edits. "
                + "Switch the workspace back to pull requests to send them."
            return false
        }
        let main = try await sync.defaultBranch(at: root)
        if let reason = try await sync.switchBranch(to: main, at: root) {
            message = "Fen didn't leave \(branch): \(reason)"
            return false
        }
        pullRequest = nil
        changed()
        return true
    }

    // MARK: - Push-as-PR

    func sendForReview(_ sync: GitSync, _ root: URL) async throws {
        guard let repo else { return }
        guard let token = sync.token(for: repo) else {
            needsToken = true
            message = "Fen needs a token to open the pull request. Add one with Set Token."
            return
        }
        let status = try await sync.status(at: root)
        let main = try await sync.defaultBranch(at: root)
        guard let branch = status.branch else {
            message = "There's no branch to send changes from."
            return
        }
        if branch == main {
            guard try await pullStep(sync, root) else { return }
            try await sendNewBranch(sync, root, repo: repo, token: token, base: main)
        } else if GitSync.isWorkingBranch(branch) {
            try await continueBranch(sync, root, repo: repo, token: token, base: main, status: status)
        } else {
            message = "This folder is on \(branch). Switch to \(main) to send changes for review."
        }
    }

    /// Branches off the current commit, commits there, pushes and opens the pull request.
    private func sendNewBranch(
        _ sync: GitSync,
        _ root: URL,
        repo: GitHubRepo,
        token: String,
        base: String
    ) async throws {
        let before = try await sync.status(at: root)
        guard before.changedFiles > 0 || before.ahead > 0 else {
            pullRequest = nil
            return
        }
        let name = GitSync.workingBranchName()
        try await sync.startBranch(name, at: root)
        let count = try await sync.commitChanges(at: root)
        guard count > 0 || before.ahead > 0 else {
            // Only files that look like secrets changed. Put the folder back as it was.
            _ = try await sync.switchBranch(to: base, at: root)
            try await sync.deleteBranch(name, at: root)
            message = "Fen left out the files that look like secrets, so there is nothing to send."
            return
        }
        guard try await sync.push(at: root) != .rejected else {
            message = "GitHub already has a branch called \(name). Try again."
            return
        }
        pullRequest = try await openPullRequest(sync, root, repo: repo, token: token, head: name, base: base)
        // Unpushed commits on the default branch now live on the pull request branch too.
        try await sync.resetBranchToRemote(base, at: root, keeping: name)
    }

    private func continueBranch(
        _ sync: GitSync,
        _ root: URL,
        repo: GitHubRepo,
        token: String,
        base: String,
        status: GitSync.Status
    ) async throws {
        guard let branch = status.branch else { return }
        let pull = try await api.pullRequest(head: branch, in: repo, token: token)
        if let pull, pull.state != .open {
            // Finished on GitHub. Go back to the default branch, or start a new set of changes from here.
            guard status.changedFiles == 0, status.ahead == 0 else {
                try await startAnotherBranch(sync, root, repo: repo, token: token, base: base)
                return
            }
            if let reason = try await sync.switchBranch(to: base, at: root) {
                message = "Fen didn't leave \(branch): \(reason)"
                return
            }
            pullRequest = nil
            _ = try await pullStep(sync, root)
            changed()
            return
        }
        if status.upstream != nil {
            guard try await pullStep(sync, root) else { return }
        }
        try await sync.commitChanges(at: root)
        switch try await sync.push(at: root) {
        case .rejected: message = "GitHub has new commits on this branch. Pull first."
        case .nothingToPush, .pushed: break
        }
        if let pull {
            pullRequest = pull
        } else {
            pullRequest = try await openPullRequest(sync, root, repo: repo, token: token, head: branch, base: base)
        }
    }

    /// A pull request is finished but you kept editing. The edits go to a new branch and a new pull request.
    private func startAnotherBranch(
        _ sync: GitSync,
        _ root: URL,
        repo: GitHubRepo,
        token: String,
        base: String
    ) async throws {
        let name = GitSync.workingBranchName()
        try await sync.startBranch(name, at: root)
        try await sync.commitChanges(at: root)
        _ = try await sync.push(at: root)
        pullRequest = try await openPullRequest(sync, root, repo: repo, token: token, head: name, base: base)
    }

    private func openPullRequest(
        _ sync: GitSync,
        _ root: URL,
        repo: GitHubRepo,
        token: String,
        head: String,
        base: String
    ) async throws -> PullRequest {
        let title = try await sync.lastSubject(at: root) ?? "Changes from Fen"
        return try await api.openPullRequest(
            head: head,
            base: base,
            title: title,
            body: "Sent from Fen.",
            in: repo,
            token: token
        )
    }

    /// Looks up the pull request for the current branch. A network problem leaves the last answer in place.
    func refreshPullRequest() async {
        guard let sync, let repo, let branch = status?.branch, GitSync.isWorkingBranch(branch) else {
            pullRequest = nil
            return
        }
        if let found = try? await api.pullRequest(head: branch, in: repo, token: sync.token(for: repo)) {
            pullRequest = found
        }
    }

    // MARK: - On save

    /// Called when files in the workspace changed. A direct-commit workspace backs up once changes stop
    /// for `saveDelay`. Changes that keep coming push the backup back. Nothing runs without a change on
    /// disk, so a backup that has nothing to do doesn't start another.
    func noteChanged() {
        guard inputs.mode() == .directCommit, repo != nil, !needsToken else { return }
        autoTask?.cancel()
        let delay = inputs.saveDelay
        autoTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await backUpIfNeeded()
        }
    }

    private func backUpIfNeeded() async {
        guard let sync, let root = root(), working == nil else { return }
        guard let files = try? await sync.changedFiles(at: root), !files.isEmpty else { return }
        await syncNow()
    }
}
