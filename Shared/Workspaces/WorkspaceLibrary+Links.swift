import Foundation

/// Wiki links and backlinks for a file that sits in a workspace (issue #36).
public extension WorkspaceLibrary {
    /// Resolves `[[names]]` for the document at `url`, or `nil` when it is in no workspace or the
    /// workspace has not been listed yet.
    func wikiLinkResolver(for url: URL?) -> WikiLinkResolver? {
        guard let url, let location = locate(url) else { return nil }
        let state = state(for: location.workspace.id)
        guard state.hasScanned else { return nil }
        return WikiLinkResolver(paths: state.snapshot.documents.map(\.relativePath), current: location.relativePath)
    }

    /// Documents that link to the file at `url`, or none when it is in no workspace.
    func backlinks(to url: URL?) async -> [Backlink] {
        guard let url, let location = locate(url) else { return [] }
        return await search.backlinks(to: location.relativePath, in: location.workspace)
    }
}
