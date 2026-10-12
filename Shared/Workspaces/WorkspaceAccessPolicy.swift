import Foundation

/// Which workspaces a query covers (issue #5). Search and Q&A offer all three.
public enum WorkspaceScope: Sendable, Equatable {
    case workspace(UUID)
    case chosen(Set<UUID>)
    case all
}

/// Where search results go. Every search must say, so one that feeds a model can't skip the AI
/// data access filter by leaving it out.
public enum SearchDestination: Sendable, Equatable {
    /// You see the results in Fen. No model is involved, so no AI data access filter.
    case shownToUser
    /// An MCP client gets them. The caller's scope holds only workspaces with MCP access on,
    /// which is off whenever AI data access is None.
    case mcpClient
    /// They feed a model there. Workspaces whose AI data access doesn't allow it are left out,
    /// even for `.all`.
    case model(ModelDestination)

    var modelDestination: ModelDestination? {
        if case let .model(destination) = self {
            return destination
        }
        return nil
    }
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
