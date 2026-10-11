import Foundation

/// A passage pair that passed the cheap check (issue #94). Only these ever reach a model.
struct ConflictCandidate: Equatable {
    var changed: ConflictSide
    var other: ConflictSide
    /// Cosine of the two passages, 0 to 1.
    var similarity: Float
    var signals: ConflictSignals

    /// Orders candidates when a cap cuts the list.
    var rank: Double {
        Double(similarity) + signals.score
    }
}

/// What the first tier did, for the cost report.
struct DetectionStats: Equatable {
    /// Passages turned into vectors.
    var embedded = 0
    /// Pairs whose vectors were compared.
    var compared = 0
    /// Pairs close enough in meaning to look at for contradiction marks.
    var related = 0
    /// Pairs that passed.
    var candidates = 0
}

/// Tier 1 of conflict detection: finds passage pairs that are about the same thing and show a mark
/// of contradiction. It runs on the device and calls no model. `embed` returns a unit-length vector.
@MainActor
struct ConflictDetector {
    struct Options: Equatable {
        /// Below this cosine two passages are about different things.
        var minSimilarity: Float = 0.6
        /// At or above this cosine a pair goes to the model even with no mark, because it is a near copy
        /// that may have drifted.
        var strongSimilarity: Float = 0.85
        /// The least mark score that makes a pair a candidate.
        var minSignal = 0.25
        /// The most passages of one note that are compared.
        var maxPassagesPerNote = 40
    }

    var options = Options()
    let embed: @MainActor (String) async -> [Float]?
    private(set) var stats = DetectionStats()
    private var vectors: [String: [Float]?] = [:]

    init(options: Options = Options(), embed: @escaping @MainActor (String) async -> [Float]?) {
        self.options = options
        self.embed = embed
    }

    /// Pairs each of `changed` with the passages of every note in `neighbors`.
    /// - Parameters:
    ///   - changed: The passages that are new or edited since the last run.
    ///   - path: The note they are in.
    ///   - neighbors: Notes near this one. Its own path is skipped.
    mutating func candidates(
        changed: [ConflictPassage],
        in path: String,
        neighbors: [(path: String, text: String)]
    ) async -> [ConflictCandidate] {
        var found: [ConflictCandidate] = []
        let split = neighbors.filter { $0.path != path }.map { neighbor in
            (
                path: neighbor.path,
                passages: Array(ConflictPassage.split(neighbor.text).prefix(options.maxPassagesPerNote))
            )
        }
        for passage in changed {
            guard let vector = await vector(for: passage) else { continue }
            for neighbor in split {
                for other in neighbor.passages where other.hash != passage.hash {
                    guard let otherVector = await self.vector(for: other) else { continue }
                    stats.compared += 1
                    let similarity = Self.cosine(vector, otherVector)
                    guard similarity >= options.minSimilarity else { continue }
                    stats.related += 1
                    let signals = ConflictSignals.compare(changed: passage.text, other: other.text)
                    guard signals.score >= options.minSignal || similarity >= options.strongSimilarity else { continue }
                    stats.candidates += 1
                    found.append(ConflictCandidate(
                        changed: ConflictSide(path: path, passage: passage),
                        other: ConflictSide(path: neighbor.path, passage: other),
                        similarity: similarity,
                        signals: signals
                    ))
                }
            }
        }
        return found.sorted { $0.rank > $1.rank }
    }

    private mutating func vector(for passage: ConflictPassage) async -> [Float]? {
        if let cached = vectors[passage.hash] {
            return cached
        }
        stats.embedded += 1
        let made = await embed(passage.text)
        vectors[passage.hash] = .some(made)
        return made
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
        }
        return dot
    }
}
