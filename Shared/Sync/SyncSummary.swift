import Foundation

/// The one line of sync state in a workspace header (issue #61). Direct-commit uses backup words and no
/// git words. Push-as-PR shows the branch and the pull request.
enum SyncSummary {
    static func text(
        mode: SyncMode,
        status: GitSync.Status?,
        pullRequest: PullRequest?,
        held: Int,
        repo: String
    ) -> String {
        guard let status else { return repo }
        switch mode {
        case .directCommit: return backup(status, pullRequest, held)
        case .pushAsPR: return review(status, pullRequest)
        }
    }

    private static func backup(_ status: GitSync.Status, _ pullRequest: PullRequest?, _ held: Int) -> String {
        if GitSync.isWorkingBranch(status.branch) {
            return pullRequest.map { "Changes wait in pull request #\($0.number)" } ?? "Changes wait on a review branch"
        }
        guard status.upstream != nil else { return "Not backed up yet" }
        var parts: [String] = []
        let waiting = max(status.changedFiles - held, 0)
        if status.behind > 0 {
            parts.append("GitHub has updates")
        }
        if waiting > 0 {
            parts.append(waiting == 1 ? "1 note not backed up" : "\(waiting) notes not backed up")
        } else if status.ahead > 0 {
            parts.append("Ready to upload")
        }
        if held > 0 {
            parts.append(held == 1 ? "1 AI change waits for you" : "\(held) AI changes wait for you")
        }
        return parts.isEmpty ? "Backed up" : parts.joined(separator: " · ")
    }

    private static func review(_ status: GitSync.Status, _ pullRequest: PullRequest?) -> String {
        guard let pullRequest else { return status.text }
        return status.text + " · PR #\(pullRequest.number) \(pullRequest.state.rawValue)"
    }
}

/// Which notes an AI change touched in place (issue #61). Changes on an agent branch are left out: they
/// are not in your files.
enum AIChangedPaths {
    /// Each path with the date of the latest applied change that is not undone. A move counts for both paths.
    static func latest(in entries: [ActivityEntry]) -> [String: Date] {
        var latest: [String: Date] = [:]
        for entry in entries where entry.branch == nil && !entry.isUndone {
            for path in [entry.path, entry.toPath].compactMap(\.self) {
                latest[path] = max(latest[path] ?? .distantPast, entry.date)
            }
        }
        return latest
    }
}
