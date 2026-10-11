import Foundation

/// A document that links to the open one (issue #36).
public struct Backlink: Sendable, Equatable, Identifiable {
    public let workspaceID: UUID
    /// Path below the workspace root, with `/` separators.
    public let relativePath: String
    public let title: String

    public var id: String {
        workspaceID.uuidString + "/" + relativePath
    }
}

public extension WorkspaceSearch {
    /// Documents of `workspace` that link to `path`, by a Markdown link or a `[[name]]`. It reads
    /// only the local index, so it finds files that are not open. A `[[name]]` counts only when it
    /// resolves to `path` the way the preview resolves it, so a file with the same name in another
    /// folder does not claim the link. The result never leaves `workspace`.
    func backlinks(to path: String, in workspace: Workspace) async -> [Backlink] {
        guard let index = indexes[workspace.id],
              let rows = try? await index.linkRows(into: path),
              let paths = try? await index.documentPaths() else { return [] }
        let resolver = WikiLinkResolver(paths: paths)
        var found: [String: Backlink] = [:]
        for row in rows where found[row.source] == nil {
            if row.kind == "wiki", resolver.target(for: row.target, from: row.source) != path {
                continue
            }
            found[row.source] = Backlink(workspaceID: workspace.id, relativePath: row.source, title: row.title)
        }
        return found.values.sorted {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order != .orderedSame ? order == .orderedAscending : $0.relativePath < $1.relativePath
        }
    }
}
