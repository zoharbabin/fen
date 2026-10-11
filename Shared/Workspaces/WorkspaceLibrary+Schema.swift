import Foundation

/// Document types for a file that sits in a workspace (issue #7).
public extension WorkspaceLibrary {
    /// The schema store of a workspace, or `nil` when its folder can't be reached.
    func schemaStore(for workspaceID: UUID) -> SchemaStore? {
        (try? registry.rootURL(for: workspaceID)).map(SchemaStore.init(root:))
    }

    /// The document types for the file at `url`: the workspace's schema file, or the built-in
    /// types when it has none. `nil` when the file is in no workspace or the schema can't be read.
    func schema(for url: URL?) async -> DocumentSchema? {
        guard let url, let location = locate(url), let store = schemaStore(for: location.workspace.id) else {
            return nil
        }
        return await Task.detached { try? store.load().schema }.value
    }
}
