import Foundation

/// One piece of a document that Fen found for a question (issue #141). It is what the model reads,
/// and what a citation points to.
public struct Passage: Sendable, Equatable, Identifiable {
    public let workspaceID: UUID
    public let workspaceName: String
    /// Path below the workspace root, with `/` separators.
    public let relativePath: String
    /// The heading trail. Empty before the first heading.
    public let heading: String
    /// 1-based line in the file where the passage starts.
    public let startLine: Int
    public let text: String

    public var id: String {
        "\(workspaceID.uuidString)/\(relativePath):\(startLine)"
    }

    public var endLine: Int {
        startLine + max(0, text.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
    }

    public var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    public var lineRange: String {
        endLine > startLine ? "lines \(startLine) to \(endLine)" : "line \(startLine)"
    }
}

extension WorkspaceSearch {
    /// The text of the best chunk of each result, read from the index. It never opens a file.
    /// Results whose workspace has no index, or whose chunk changed since, are left out.
    func passages(for results: [SearchResult]) async -> [Passage] {
        var found: [Passage] = []
        for result in results {
            guard let index = indexes[result.workspaceID],
                  let text = try? await index.chunkText(path: result.relativePath, startLine: result.startLine)
            else { continue }
            found.append(Passage(
                workspaceID: result.workspaceID,
                workspaceName: result.workspaceName,
                relativePath: result.relativePath,
                heading: result.heading,
                startLine: result.startLine,
                text: text
            ))
        }
        return found
    }
}
