import Foundation

/// A document that touches the text you are working on (issue #8).
public struct RelatedSuggestion: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable, CaseIterable {
        case linksHere
        case linkedFromHere
        case similarPassage
        case sharedWords
        case sameFolder

        public var label: String {
            switch self {
            case .linksHere: "Links to this page"
            case .linkedFromHere: "Linked from this page"
            case .similarPassage: "Similar passage"
            case .sharedWords: "Shares words"
            case .sameFolder: "Same folder"
            }
        }
    }

    public let workspaceID: UUID
    public let relativePath: String
    public let title: String
    public let heading: String
    public let startLine: Int
    /// The passage that matched.
    public let passage: String
    public let reasons: [Reason]
    public let score: Double

    public var id: String {
        relativePath
    }

    public var reasonText: String {
        reasons.map(\.label).joined(separator: " · ")
    }

    /// A Markdown link to this document, relative to the file you are editing. `text` is the link
    /// text, or the document's title when empty.
    public func markdownLink(from currentPath: String, text: String? = nil) -> String {
        let shown = (text?.isEmpty == false ? text : nil) ?? (title.isEmpty ? fileStem : title)
        let target = Self.relativePath(from: currentPath, to: relativePath)
        let encoded = target.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let safe = shown.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(safe)](\(encoded))"
    }

    private var fileStem: String {
        ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func relativePath(from current: String, to target: String) -> String {
        let from = current.split(separator: "/").dropLast().map(String.init)
        let to = target.split(separator: "/").map(String.init)
        var shared = 0
        while shared < from.count, shared < to.count - 1, from[shared] == to[shared] {
            shared += 1
        }
        let ups = Array(repeating: "..", count: from.count - shared)
        return (ups + to[shared...]).joined(separator: "/")
    }
}

enum RelatedQuery {
    private static let ignored: Set<String> = [
        "this", "that", "with", "from", "have", "will", "your", "about", "into", "there", "their", "which", "would",
        "been", "were", "when", "what", "they", "them", "then", "than", "also", "more", "some", "such", "only",
    ]

    /// The few words most likely to name the topic: the longest distinct ones, in the order they appear.
    static func keywords(from text: String, limit: Int = 8) -> String {
        var seen = Set<String>()
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 4 && !ignored.contains($0) && seen.insert($0).inserted }
        let chosen = Set(words.sorted { $0.count > $1.count }.prefix(limit))
        return words.filter { chosen.contains($0) }.joined(separator: " ")
    }

    /// The most text worth embedding for a selection or a paragraph.
    static let maxMeaningCharacters = 600
}

extension WorkspaceSearch {
    /// Documents in `workspace` that relate to `text`, which you selected or are writing in `path`.
    ///
    /// Relatedness mixes the index's word and meaning matches with links to and from `path` and the
    /// folder it sits in. It reads only the local index, calls no model and no network, and never
    /// leaves `workspace`. `path` itself is never returned.
    public func related(
        to text: String,
        from path: String,
        in workspace: Workspace,
        limit: Int = 5
    ) async -> [RelatedSuggestion] {
        let keywords = RelatedQuery.keywords(from: text)
        let meaning = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(RelatedQuery.maxMeaningCharacters))
        guard !keywords.isEmpty, indexes[workspace.id] != nil else { return [] }
        let results = await search(
            keywords,
            meaning: meaning,
            anyWord: true,
            in: [workspace],
            scope: .workspace(workspace.id),
            origin: SearchOrigin(workspaceID: workspace.id, relativePath: path),
            limit: limit * 4 + 1
        )
        let links = await (try? indexes[workspace.id]?.linkedPaths(of: path)) ?? (outgoing: [], incoming: [])
        let folder = (path as NSString).deletingLastPathComponent
        let suggestions = results.filter { $0.relativePath != path }.map { result -> RelatedSuggestion in
            var reasons: [RelatedSuggestion.Reason] = []
            var score = result.score
            if links.incoming.contains(result.relativePath) {
                reasons.append(.linksHere)
                score += Self.linkWeight
            }
            if links.outgoing.contains(result.relativePath) {
                reasons.append(.linkedFromHere)
                score += Self.linkWeight
            }
            if result.match != .words {
                reasons.append(.similarPassage)
            }
            if result.match != .meaning {
                reasons.append(.sharedWords)
            }
            if !folder.isEmpty, (result.relativePath as NSString).deletingLastPathComponent == folder {
                reasons.append(.sameFolder)
            }
            return RelatedSuggestion(
                workspaceID: workspace.id, relativePath: result.relativePath, title: result.title,
                heading: result.heading, startLine: result.startLine, passage: result.snippet,
                reasons: reasons, score: score
            )
        }
        return Array(suggestions.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// A direct link outweighs a rank step: it is the strongest sign two notes belong together.
    private static let linkWeight = 0.01
}
