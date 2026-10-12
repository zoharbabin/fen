import Foundation

/// Who may see a file, and whether AI may change it (issue #6). The editor actions and the
/// workspace file action ask the same question here.
@MainActor
enum InlineAIAccess {
    /// Why `operation` (`rewrite` or `enrich`) can't run for this file, or `nil` when it can.
    static func reason(library: WorkspaceLibrary, service: AIService, fileURL: URL?, operation: String) -> String? {
        let destination: ModelDestination
        do {
            destination = try service.destination()
        } catch {
            return error.localizedDescription
        }
        guard let fileURL, let place = library.locate(fileURL) else {
            if operation == "enrich" {
                return "Enrich reads your workspace. Add this file's folder as a workspace first."
            }
            return destination == .local ? nil : "This file is in no workspace, so only a local provider may see it."
        }
        let settings = place.workspace.settings
        let mode = settings.writePolicy.mode(
            workspaceDefault: settings.approvalMode,
            operation: operation,
            documentType: nil,
            paths: [place.relativePath],
            client: nil
        )
        if mode == .off {
            return "AI changes are off in \(place.workspace.name)."
        }
        guard settings.allowsModel(at: destination) else {
            return AIError.workspaceDisallows(
                workspace: place.workspace.name, access: settings.aiDataAccess, destination: destination
            ).localizedDescription
        }
        return nil
    }
}
