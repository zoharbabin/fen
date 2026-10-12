import Foundation

/// Turns the name in a `[[wiki link]]` into a document of one workspace (issue #36).
///
/// A name matches the same way the search index matches it (`MarkdownChunker.wikiKey`): lowercase,
/// no extension, against a file's name or its whole path. The resolver only knows the files of one
/// workspace, so a name can never reach a file in another one.
public struct WikiLinkResolver: Sendable {
    private let current: String
    private let byKey: [String: [String]]

    /// - Parameters:
    ///   - paths: every document of the workspace, as paths relative to its root.
    ///   - current: the open document's path, relative to the same root.
    public init(paths: [String], current: String = "") {
        self.current = current
        var table: [String: Set<String>] = [:]
        for path in paths {
            table[MarkdownChunker.wikiKey((path as NSString).lastPathComponent), default: []].insert(path)
            table[MarkdownChunker.wikiKey(path), default: []].insert(path)
        }
        byKey = table.mapValues { $0.sorted() }
    }

    /// The path of the document `name` points to, relative to the open document, or `nil`.
    public func resolve(_ name: String) -> String? {
        target(for: name, from: current).map { RelatedSuggestion.relativePath(from: current, to: $0) }
    }

    /// The workspace path `name` points to when written in the document `source`. When several
    /// files share the name, the one nearest to `source` wins.
    public func target(for name: String, from source: String) -> String? {
        let key = MarkdownChunker.wikiKey(name)
        guard !key.isEmpty, let candidates = byKey[key] else { return nil }
        return candidates.min { lhs, rhs in
            let (left, right) = (distance(from: source, to: lhs), distance(from: source, to: rhs))
            return left != right ? left < right : lhs.count < rhs.count
        }
    }

    /// Folder steps between two documents. Fewer is nearer.
    private func distance(from source: String, to path: String) -> Int {
        let from = source.split(separator: "/").dropLast()
        let to = path.split(separator: "/").dropLast()
        let shared = zip(from, to).prefix { $0 == $1 }.count
        return (from.count - shared) + (to.count - shared)
    }
}
