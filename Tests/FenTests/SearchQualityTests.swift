@testable import FenCore
import Foundation
import NaturalLanguage
import Testing

/// A small, hand-labeled set to check that the Apple on-device embedder helps and the hybrid
/// ranking never does worse than either half. Set `FEN_SPIKE=1` to print the numbers that
/// `docs/spikes/embedding-model.md` quotes.
// swiftlint:disable line_length
enum QualityCorpus {
    static let documents: [String: String] = [
        "release.md": "# Releasing\nTag the commit, then the workflow builds the app. It signs the archive and sends it to Apple for notarization before upload.",
        "backup.md": "# Backups\nCopy your notes to an external drive every week. Keep one copy off site in case of fire or theft.",
        "password.md": "# Passwords\nUse a password manager. Never reuse a login across sites, and turn on two-factor authentication.",
        "garden.md": "# Garden\nWater the tomatoes early in the morning. Tie the stems to a stake and remove the small side shoots.",
        "budget.md": "# Budget\nTrack monthly spending in a spreadsheet. Set aside part of each paycheck for savings before paying bills.",
        "travel.md": "# Trip to Lisbon\nBook the flight in March. We will stay near the old tram line and take a day trip to the coast.",
        "cooking.md": "# Weeknight dinners\nRoast vegetables with olive oil and garlic. Cook the pasta until it is just firm and toss it with the sauce.",
        "meeting.md": "# Team sync\nAgenda: sprint review, open bugs, hiring plan. Action items go to the shared board after the call.",
        "bike.md": "# Bike repair\nThe rear tire has a slow leak. Patch the inner tube and check the brake pads before the next ride.",
        "reading.md": "# Reading list\nA novel about a lighthouse keeper, a history of the printing press, and a short guide to bird songs.",
        "sleep.md": "# Sleep\nGo to bed at the same hour each night. Avoid screens and coffee late in the day to rest better.",
        "api.md": "# API design\nReturn clear error codes. Version the endpoints and document every field in the response body.",
    ]

    /// Query and the one file that answers it. Half share no word with their answer.
    static let queries: [(String, String)] = [
        ("how do we notarize the build", "release.md"),
        ("protect my files from disk failure", "backup.md"),
        ("keeping accounts safe from hackers", "password.md"),
        ("when to irrigate vegetables", "garden.md"),
        ("saving money each month", "budget.md"),
        ("vacation in Portugal", "travel.md"),
        ("what to make for supper", "cooking.md"),
        ("agenda for the staff call", "meeting.md"),
        ("flat tyre on my bicycle", "bike.md"),
        ("books I want to read", "reading.md"),
        ("trouble falling asleep", "sleep.md"),
        ("REST endpoint versioning", "api.md"),
        ("two-factor", "password.md"),
        ("tram", "travel.md"),
        ("brake pads", "bike.md"),
        ("pasta sauce", "cooking.md"),
    ]
}

// swiftlint:enable line_length

@Suite("Search quality with the Apple embedder (issue #35)", .serialized)
struct SearchQualityTests {
    private let provider = AppleSentenceEmbeddingProvider()

    private struct Scores {
        var reciprocalRank = 0.0
        var top1 = 0
        var top3 = 0
    }

    private func score(_ ranked: [String], answer: String, into scores: inout Scores) {
        guard let position = ranked.firstIndex(of: answer) else { return }
        scores.reciprocalRank += 1 / Double(position + 1)
        scores.top1 += position == 0 ? 1 : 0
        scores.top3 += position < 3 ? 1 : 0
    }

    @Test("hybrid ranking is at least as good as words alone and as meaning alone")
    func hybridBeatsParts() async throws {
        try #require(provider.isAvailable, "The on-device sentence model isn't installed on this machine.")
        let folder = try TempFolder("quality")
        defer { folder.cleanUp() }
        let identity = EmbedderIdentity(id: provider.id, spaces: provider.spaces)
        let index = SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: identity)
        let source = MemorySource(contents: QualityCorpus.documents)
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: provider)
        let workspace = UUID()

        func evaluate(floor: Float) async throws -> (words: Scores, meaning: Scores, hybrid: Scores) {
            var words = Scores(), meaning = Scores(), hybrid = Scores()
            for (query, answer) in QualityCorpus.queries {
                let text = try await index.textCandidates(matching: query, limit: 50)
                let vector = try await index.vectorCandidates(for: provider.embed(query), space: "en", limit: 50)
                score(text.map(\.path), answer: answer, into: &words)
                score(vector.filter { $0.score >= Double(floor) }.map(\.path), answer: answer, into: &meaning)
                let fused = HybridRanker.rank(
                    [WorkspaceCandidates(workspaceID: workspace, workspaceName: "w", text: text, vector: vector)],
                    similarityFloor: floor, origin: nil, limit: 10
                )
                score(fused.map(\.relativePath), answer: answer, into: &hybrid)
            }
            return (words, meaning, hybrid)
        }

        let count = Double(QualityCorpus.queries.count)
        for floor: Float in [0, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.45] {
            let result = try await evaluate(floor: floor)
            print("QUALITY floor \(floor) words MRR \(result.words.reciprocalRank / count) top3 \(result.words.top3)"
                + " | meaning MRR \(result.meaning.reciprocalRank / count) top3 \(result.meaning.top3)"
                +
                " | hybrid MRR \(result.hybrid.reciprocalRank / count) top1 \(result.hybrid.top1) top3 \(result.hybrid.top3) of \(Int(count))")
        }
        let chosen = try await evaluate(floor: provider.similarityFloor)
        #expect(chosen.hybrid.reciprocalRank >= chosen.words.reciprocalRank)
        #expect(chosen.hybrid.reciprocalRank >= chosen.meaning.reciprocalRank)
        #expect(chosen.hybrid.top3 > chosen.words.top3)

        let nonsense = try await provider.embed("quantum xylophone zebra")
        let weak = try await index.vectorCandidates(for: nonsense, space: "en", limit: 50)
            .filter { $0.score >= Double(provider.similarityFloor) }
        print("QUALITY nonsense query keeps \(weak.count) of \(QualityCorpus.documents.count) chunks above the floor")
    }

    @Test(
        "spike: similarity of right and wrong answers, speed, and size (FEN_SPIKE=1 prints them)",
        .enabled(if: ProcessInfo.processInfo.environment["FEN_SPIKE"] != nil)
    )
    func spike() async throws {
        try #require(provider.isAvailable)
        let folder = try TempFolder("spike")
        defer { folder.cleanUp() }
        let identity = EmbedderIdentity(id: provider.id, spaces: provider.spaces)
        let index = SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: identity)
        let source = MemorySource(contents: QualityCorpus.documents)
        let start = ContinuousClock.now
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: provider)
        print(
            "SPIKE sentence index+embed per document \((ContinuousClock.now - start) / QualityCorpus.documents.count)"
        )
        var right: [Float] = [], wrong: [Float] = []
        for (query, answer) in QualityCorpus.queries {
            let found = try await index.vectorCandidates(for: provider.embed(query), space: "en", limit: 50)
            for hit in found {
                if hit.path == answer {
                    right.append(Float(hit.score))
                } else {
                    wrong.append(Float(hit.score))
                }
            }
        }
        right.sort()
        wrong.sort()
        let pick: ([Float], Double) -> Float = { $0[min($0.count - 1, Int(Double($0.count) * $1))] }
        print("SPIKE sentence right  min \(right[0]) p25 \(pick(right, 0.25)) median \(pick(right, 0.5))")
        print(
            "SPIKE sentence wrong  median \(pick(wrong, 0.5)) p90 \(pick(wrong, 0.9)) p99 \(pick(wrong, 0.99)) max \(wrong.last ?? 0)"
        )
    }

    /// Mean-pools Apple's contextual (BERT-style) model into one vector per text, if its assets are
    /// already on this Mac. We never ask the system to download them.
    @Test(
        "spike: contextual embedding, only if its assets are already installed",
        .enabled(if: ProcessInfo.processInfo.environment["FEN_SPIKE"] != nil)
    )
    func contextualSpike() throws {
        guard let model = NLContextualEmbedding(language: .english) else {
            print("SPIKE contextual: no English model")
            return
        }
        print(
            "SPIKE contextual assets installed: \(model.hasAvailableAssets) dimension \(model.dimension) maxLength \(model.maximumSequenceLength)"
        )
        guard model.hasAvailableAssets else { return }
        try model.load()
        func pooled(_ text: String) throws -> [Float] {
            let result = try model.embeddingResult(for: text, language: .english)
            var sum = [Double](repeating: 0, count: model.dimension)
            var tokens = 0
            result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() {
                    sum[index] += value
                }
                tokens += 1
                return true
            }
            return VectorCodec.normalized(sum.map { Float($0 / Double(max(tokens, 1))) }) ?? []
        }
        let paths = QualityCorpus.documents.keys.sorted()
        let start = ContinuousClock.now
        var vectors: [String: [Float]] = [:]
        for path in paths {
            vectors[path] = try pooled(QualityCorpus.documents[path] ?? "")
        }
        print("SPIKE contextual embed per call \((ContinuousClock.now - start) / paths.count)")
        var right: [Float] = [], wrong: [Float] = []
        var reciprocal = 0.0
        for (query, answer) in QualityCorpus.queries {
            let queryVector = try pooled(query)
            let scored = paths.map { path in (
                path,
                zip(queryVector, vectors[path] ?? []).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            ) }
            for (path, cosine) in scored {
                if path == answer {
                    right.append(cosine)
                } else {
                    wrong.append(cosine)
                }
            }
            let order = scored.sorted { $0.1 > $1.1 }.map(\.0)
            if let position = order.firstIndex(of: answer) {
                reciprocal += 1 / Double(position + 1)
            }
        }
        right.sort()
        wrong.sort()
        print("SPIKE contextual MRR (meaning only, no floor) \(reciprocal / Double(QualityCorpus.queries.count))")
        print(
            "SPIKE contextual right min \(right[0]) median \(right[right.count / 2]); wrong median \(wrong[wrong.count / 2]) max \(wrong.last ?? 0)"
        )
    }
}
