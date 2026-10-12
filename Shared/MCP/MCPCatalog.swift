import Foundation

/// A document's title and type, for listing by type without opening files (issue #10).
struct MCPCatalogEntry: Sendable, Equatable {
    var path: String
    var title: String
    var type: String?
    var size: Int
    var modified: Date
}

/// The titles and types of a workspace's documents. The search index has no type column, so this
/// reads front matter from the files. It remembers what it read, keyed by file size and modified
/// time, so a second call only reads files that changed.
actor MCPCatalog {
    private struct Key: Hashable {
        var workspace: UUID
        var path: String
    }

    private var cache: [Key: MCPCatalogEntry] = [:]

    /// Entries for `files`, in the order given. Files that can't be read are left out.
    func entries(workspace: UUID, files: [WorkspaceFile], source: LocalFolderSource) throws -> [MCPCatalogEntry] {
        let renderer = MarkdownRenderer()
        var result: [MCPCatalogEntry] = []
        for file in files {
            try Task.checkCancellation()
            let key = Key(workspace: workspace, path: file.relativePath)
            if let known = cache[key], known.size == file.size, known.modified == file.modified {
                result.append(known)
                continue
            }
            guard let data = try? source.read(relativePath: file.relativePath), data.count <= SchemaMigration.maxBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }
            let type = text.hasPrefix("---") ? DocumentProperties.typeName(in: renderer.peekFrontMatter(text)) : nil
            let entry = MCPCatalogEntry(
                path: file.relativePath,
                title: MarkdownChunker.parse(text, path: file.relativePath).title,
                type: type?.isEmpty == true ? nil : type,
                size: file.size,
                modified: file.modified
            )
            cache[key] = entry
            result.append(entry)
        }
        return result
    }

    func forget(workspace: UUID) {
        cache = cache.filter { $0.key.workspace != workspace }
    }
}
