import Foundation

/// Which kind of scope the search box is set to.
enum WorkspaceSearchScope: Hashable, CaseIterable {
    case workspace
    case chosen
    case all
}

/// Turns what you picked in the search box into the `WorkspaceScope` a query runs with (issue #35).
///
/// This is for display. Results are shown to you, so any granted workspace may take part. A query
/// that feeds a model goes through `WorkspaceAccessPolicy` with its own destination instead.
struct SearchScopeSelection: Equatable {
    var mode = WorkspaceSearchScope.all
    var chosen: Set<UUID> = []

    /// - Parameters:
    ///   - current: the workspace selected in the sidebar, for "This Workspace".
    ///   - available: the workspaces that are granted now. Ids of removed workspaces are dropped.
    func scope(current: UUID?, available: [Workspace]) -> WorkspaceScope {
        switch mode {
        case .all:
            return .all
        case .workspace:
            guard let current, available.contains(where: { $0.id == current }) else { return .all }
            return .workspace(current)
        case .chosen:
            return .chosen(liveChosen(in: available))
        }
    }

    /// `false` only when every result comes from the one workspace you are in, so its name adds nothing.
    func showsWorkspaceName(current: UUID?, available: [Workspace]) -> Bool {
        if case .workspace = scope(current: current, available: available) {
            return false
        }
        return true
    }

    /// `true` when "Chosen Workspaces" is on but nothing is checked. The list is empty then, and the
    /// view tells you why.
    func needsChoice(available: [Workspace]) -> Bool {
        mode == .chosen && liveChosen(in: available).isEmpty
    }

    /// Checks or unchecks one workspace.
    mutating func toggle(_ id: UUID) {
        if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
        }
    }

    /// A short label for the picker button, such as "2 of 3 workspaces".
    func summary(available: [Workspace]) -> String {
        let live = liveChosen(in: available)
        switch live.count {
        case 0: return "Choose workspaces"
        case 1: return available.first { live.contains($0.id) }?.name ?? "1 workspace"
        default: return "\(live.count) of \(available.count) workspaces"
        }
    }

    private func liveChosen(in available: [Workspace]) -> Set<UUID> {
        chosen.intersection(available.map(\.id))
    }
}
