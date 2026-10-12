import Foundation

/// The one place that decides whether workspace content may go to a provider (issues #4, #5).
/// It refuses the whole request when any item belongs to a workspace whose AI data access
/// doesn't allow the provider. Nothing is dropped silently.
public enum AIGateway {
    public static func authorize(
        context: [AIContextItem],
        destination: ModelDestination,
        workspaces: [Workspace]
    ) throws {
        for item in context {
            guard let id = item.workspaceID else { continue }
            guard let workspace = workspaces.first(where: { $0.id == id }) else {
                throw AIError.unknownWorkspace
            }
            guard workspace.settings.allowsModel(at: destination) else {
                throw AIError.workspaceDisallows(
                    workspace: workspace.name,
                    access: workspace.settings.aiDataAccess,
                    destination: destination
                )
            }
        }
    }
}
