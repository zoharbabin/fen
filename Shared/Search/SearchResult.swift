import Foundation

/// One file found by a search (issue #35). A file shows up once, with its best matching chunk.
public struct SearchResult: Sendable, Equatable, Identifiable {
    public enum Match: Sendable, Equatable {
        case words
        case meaning
        case both
    }

    public let workspaceID: UUID
    public let workspaceName: String
    /// Path below the workspace root, with `/` separators.
    public let relativePath: String
    public let title: String
    /// The heading trail of the best chunk. Empty before the first heading.
    public let heading: String
    public let startLine: Int
    public let snippet: String
    public let match: Match
    public let score: Double

    public var id: String {
        workspaceID.uuidString + "/" + relativePath
    }

    public var fileName: String {
        (relativePath as NSString).lastPathComponent
    }
}

/// Where a search query starts from, for the path-proximity part of the score.
public struct SearchOrigin: Sendable, Equatable {
    public let workspaceID: UUID
    public let relativePath: String

    public init(workspaceID: UUID, relativePath: String) {
        self.workspaceID = workspaceID
        self.relativePath = relativePath
    }
}

/// What one workspace's index returned for a query.
struct WorkspaceCandidates: Sendable {
    let workspaceID: UUID
    let workspaceName: String
    let text: [TextCandidate]
    let vector: [VectorCandidate]
}

/// Combines word matches and meaning matches into one ranked list (issue #35).
///
/// Each list is ranked on its own, across all workspaces. The two ranks are fused with
/// reciprocal rank fusion, which needs no tuning between BM25 scores and cosines. Two small
/// boosts then break ties: files that other files link to, and files near the one you are in.
enum HybridRanker {
    static let rankOffset = 60.0
    /// The most a link or path boost can add. Ranks 1 and 3 in one list differ by about 0.0005, so
    /// a boost can swap neighbors but cannot lift a weak match over a strong one.
    static let maxLinkBoost = 0.0004
    static let maxProximityBoost = 0.0004

    static func rank(
        _ inputs: [WorkspaceCandidates],
        similarityFloor: Float,
        origin: SearchOrigin?,
        limit: Int
    ) -> [SearchResult] {
        struct Key: Hashable {
            let workspace: UUID
            let chunk: Int64
        }
        struct Entry {
            var workspaceID: UUID
            var workspaceName: String
            var path: String
            var title: String
            var heading: String
            var startLine: Int
            var snippet: String
            var inbound: Int
            var score = 0.0
            var byWords = false
            var byMeaning = false
        }
        var entries: [Key: Entry] = [:]

        let words = inputs.flatMap { input in input.text.map { (input, $0) } }.sorted { $0.1.score > $1.1.score }
        for (rank, pair) in words.enumerated() {
            let (input, hit) = pair
            let key = Key(workspace: input.workspaceID, chunk: hit.chunkID)
            var entry = entries[key] ?? Entry(
                workspaceID: input.workspaceID, workspaceName: input.workspaceName, path: hit.path,
                title: hit.title, heading: hit.heading, startLine: hit.startLine, snippet: hit.snippet,
                inbound: hit.inbound
            )
            entry.score += 1 / (rankOffset + Double(rank + 1))
            entry.byWords = true
            entry.snippet = hit.snippet
            entries[key] = entry
        }

        let meanings = inputs
            .flatMap { input in input.vector.map { (input, $0) } }
            .filter { $0.1.score >= Double(similarityFloor) }
            .sorted { $0.1.score > $1.1.score }
        for (rank, pair) in meanings.enumerated() {
            let (input, hit) = pair
            let key = Key(workspace: input.workspaceID, chunk: hit.chunkID)
            var entry = entries[key] ?? Entry(
                workspaceID: input.workspaceID, workspaceName: input.workspaceName, path: hit.path,
                title: hit.title, heading: hit.heading, startLine: hit.startLine, snippet: hit.snippet,
                inbound: hit.inbound
            )
            entry.score += 1 / (rankOffset + Double(rank + 1))
            entry.byMeaning = true
            entries[key] = entry
        }

        var best: [String: SearchResult] = [:]
        for entry in entries.values {
            let score = entry.score + linkBoost(entry.inbound)
                + proximityBoost(origin: origin, workspaceID: entry.workspaceID, path: entry.path)
            let key = entry.workspaceID.uuidString + "/" + entry.path
            if let current = best[key], current.score >= score {
                continue
            }
            best[key] = SearchResult(
                workspaceID: entry.workspaceID,
                workspaceName: entry.workspaceName,
                relativePath: entry.path,
                title: entry.title,
                heading: entry.heading,
                startLine: entry.startLine,
                snippet: entry.snippet,
                match: entry.byWords && entry.byMeaning ? .both : (entry.byWords ? .words : .meaning),
                score: score
            )
        }
        return Array(
            best.values.sorted { ($0.score, $1.relativePath) > ($1.score, $0.relativePath) }.prefix(limit)
        )
    }

    private static func linkBoost(_ inbound: Int) -> Double {
        guard inbound > 0 else { return 0 }
        return maxLinkBoost * min(log2(1 + Double(inbound)), 4) / 4
    }

    private static func proximityBoost(origin: SearchOrigin?, workspaceID: UUID, path: String) -> Double {
        guard let origin, origin.workspaceID == workspaceID else { return 0 }
        let from = origin.relativePath.split(separator: "/").dropLast()
        let to = path.split(separator: "/").dropLast()
        let shared = zip(from, to).prefix(while: { $0 == $1 }).count
        let depth = max(from.count, to.count)
        guard depth > 0 else { return maxProximityBoost }
        return maxProximityBoost * Double(shared) / Double(depth)
    }
}
