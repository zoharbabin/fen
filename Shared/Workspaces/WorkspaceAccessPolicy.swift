import Foundation

/// Which workspaces a query covers (issue #5). Search and Q&A offer all three.
public enum WorkspaceScope: Sendable, Equatable {
    case workspace(UUID)
    case chosen(Set<UUID>)
    case all
}

/// The one place that decides which workspaces may take part in a query. A scope never overrides
/// a workspace's AI data access setting: a workspace set to None is dropped from every query that
/// sends content to a model, even for `.all`. The provider layer (#4) calls this before it sends.
public enum WorkspaceAccessPolicy {
    /// - Parameter destination: where content would go, or `nil` when no model is involved
    ///   (full-text search, the local index, listing).
    public static func eligible(
        _ workspaces: [Workspace],
        scope: WorkspaceScope,
        destination: ModelDestination?
    ) -> [Workspace] {
        let inScope: [Workspace] = switch scope {
        case let .workspace(id): workspaces.filter { $0.id == id }
        case let .chosen(ids): workspaces.filter { ids.contains($0.id) }
        case .all: workspaces
        }
        guard let destination else { return inScope }
        return inScope.filter { $0.settings.allowsModel(at: destination) }
    }
}

public extension WorkspaceRegistry {
    func eligibleWorkspaces(scope: WorkspaceScope, destination: ModelDestination?) -> [Workspace] {
        WorkspaceAccessPolicy.eligible(workspaces, scope: scope, destination: destination)
    }
}
