@testable import FenCore
import Foundation
import Testing

/// Hand-labeled sets for the languages Apple's sentence models cover (issue #234), plus one
/// workspace that mixes them. The data is in `MultilingualQualityCorpus.swift`. Set `FEN_SPIKE=1` to
/// print the numbers that `docs/spikes/embedding-model.md` quotes.
@Suite("Search quality in every language the OS covers (issue #234)", .serialized)
struct MultilingualQualityTests {
    private let provider = AppleSentenceEmbeddingProvider()
    private let spike = ProcessInfo.processInfo.environment["FEN_SPIKE"] != nil

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

    private func index(
        _ documents: [String: String],
        in folder: TempFolder
    ) async throws -> SearchIndex {
        let identity = EmbedderIdentity(id: provider.id, spaces: provider.spaces)
        let index = SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: identity)
        let source = MemorySource(contents: documents)
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: provider)
        return index
    }

    private func requireModel(_ tag: String) throws {
        try #require(
            provider.spaces.contains { $0.tag == tag },
            "This OS has no \(tag) sentence model."
        )
    }

    private struct Result {
        var words = Scores()
        var meaning = Scores()
        var hybrid = Scores()
        var right: [Float] = []
        var wrong: [Float] = []
        /// Queries the language recognizer put in another language's space. Short words are the usual cause.
        var misread = 0
    }

    private func evaluate(_ corpus: LanguageCorpus, index: SearchIndex, floor: Float) async throws -> Result {
        let workspace = UUID()
        var result = Result()
        for (query, answer) in corpus.queries {
            let text = try await index.textCandidates(matching: query, limit: 50)
            // A query the recognizer can't place has no meaning results. Its words still count.
            var vector: [VectorCandidate] = []
            do {
                let tagged = try await provider.embedTagged(query)
                if tagged.space == corpus.tag {
                    vector = try await index.vectorCandidates(for: tagged.vector, space: tagged.space, limit: 50)
                } else {
                    result.misread += 1
                }
            } catch is EmbeddingTextError {
                result.misread += 1
            }
            score(text.map(\.path), answer: answer, into: &result.words)
            score(vector.filter { $0.score >= Double(floor) }.map(\.path), answer: answer, into: &result.meaning)
            let fused = HybridRanker.rank(
                [WorkspaceCandidates(workspaceID: workspace, workspaceName: "w", text: text, vector: vector)],
                similarityFloor: floor, origin: nil, limit: 10
            )
            score(fused.map(\.relativePath), answer: answer, into: &result.hybrid)
            for hit in vector {
                if hit.path == answer {
                    result.right.append(Float(hit.score))
                } else {
                    result.wrong.append(Float(hit.score))
                }
            }
        }
        return result
    }

    @Test(
        "meaning search helps and hybrid ranking never does worse than words alone",
        arguments: MultilingualCorpus.all.map(\.tag)
    )
    func perLanguage(tag: String) async throws {
        try requireModel(tag)
        let corpus = try #require(MultilingualCorpus.all.first { $0.tag == tag })
        let folder = try TempFolder("quality-\(tag)")
        defer { folder.cleanUp() }
        let index = try await index(corpus.documents, in: folder)
        let count = Double(corpus.queries.count)
        let floor = provider.similarityFloor(inSpace: tag)

        if spike {
            for candidate: Float in [0, 0.05, 0.1, 0.2, 0.3, 0.35, 0.45, 0.5, 0.55, 0.6, 0.7] {
                let result = try await evaluate(corpus, index: index, floor: candidate)
                print("QUALITY \(tag) floor \(candidate) words MRR \(result.words.reciprocalRank / count)"
                    + " | meaning MRR \(result.meaning.reciprocalRank / count)"
                    + " | hybrid MRR \(result.hybrid.reciprocalRank / count) top1 \(result.hybrid.top1)"
                    + " top3 \(result.hybrid.top3) of \(Int(count))")
            }
            let all = try await evaluate(corpus, index: index, floor: 0)
            let right = all.right.sorted(), wrong = all.wrong.sorted()
            let pick: ([Float], Double) -> Float = { $0[min($0.count - 1, Int(Double($0.count) * $1))] }
            print("QUALITY \(tag) cosine right median \(pick(right, 0.5)) p25 \(pick(right, 0.25))"
                + " | wrong median \(pick(wrong, 0.5)) p90 \(pick(wrong, 0.9)) max \(wrong.last ?? 0)")
        }

        let chosen = try await evaluate(corpus, index: index, floor: floor)
        if spike {
            print("QUALITY \(tag) misread \(chosen.misread) of \(Int(count)) queries")
        }
        #expect(Double(chosen.misread) / count <= 0.25)
        #expect(chosen.hybrid.reciprocalRank >= chosen.words.reciprocalRank)
        #expect(chosen.hybrid.top3 >= chosen.words.top3)
        #expect(chosen.meaning.reciprocalRank / count >= 0.3)
    }

    @Test("a workspace that mixes languages finds each note in the language of the query")
    func mixedWorkspace() async throws {
        let covered = MultilingualCorpus.all.filter { corpus in provider.spaces.contains { $0.tag == corpus.tag } }
        try #require(covered.count == MultilingualCorpus.all.count, "Not every language model is installed.")
        try requireModel("en")
        // One file per topic and language, plus the English set and a Dutch note no model covers.
        var documents: [String: String] = [:]
        for (name, text) in QualityCorpus.documents {
            documents["en/\(name)"] = text
        }
        for corpus in covered {
            for (name, text) in corpus.documents {
                documents["\(corpus.tag)/\(name)"] = text
            }
        }
        documents["nl/fiets.md"] = "# Fiets repareren\nDe achterband loopt langzaam leeg. "
            + "Plak de binnenband en controleer de remblokken voor de volgende rit."
        let folder = try TempFolder("quality-mixed")
        defer { folder.cleanUp() }
        let index = try await index(documents, in: folder)

        let summary = try await index.summary()
        #expect(summary.documents == documents.count)
        #expect(summary.embeddedChunks == documents.count - 1, "Every note but the Dutch one has a vector.")

        var found = 0
        var total = 0
        for corpus in covered {
            for (query, answer) in corpus.queries {
                // A query the recognizer can't place falls back to words, so it finds nothing here.
                let tagged = try? await provider.embedTagged(query)
                let hits = if let tagged {
                    try await index.vectorCandidates(for: tagged.vector, space: tagged.space, limit: 50)
                } else {
                    [VectorCandidate]()
                }
                // Only notes of the query's own language are compared with it.
                #expect(hits.allSatisfy { $0.path.hasPrefix("\(tagged?.space ?? "")/") })
                let floor = Double(provider.similarityFloor(inSpace: tagged?.space ?? ""))
                let kept = hits.filter { $0.score >= floor }
                total += 1
                found += kept.prefix(3).contains { $0.path == "\(corpus.tag)/\(answer)" } ? 1 : 0
            }
        }
        if spike {
            print("QUALITY mixed workspace: answer in the top 3 by meaning for \(found) of \(total) queries")
        }
        #expect(Double(found) / Double(total) >= 0.45)

        // A language with no model is still found by words.
        let dutch = try await index.textCandidates(matching: "remblokken", limit: 5)
        #expect(dutch.map(\.path) == ["nl/fiets.md"])
    }

    @Test("text in a language with no model gets no vector, and text with a model gets one of its size")
    func tagging() async throws {
        try requireModel("es")
        try requireModel("en")
        let spanish = try await provider.embedTagged("Riega los tomates a primera hora de la mañana.")
        #expect(spanish.space == "es")
        #expect(spanish.vector.count == provider.spaces.first { $0.tag == "es" }?.dimension)
        let english = try await provider.embedTagged("Water the tomatoes early in the morning.")
        #expect(english.space == "en")
        #expect(english.vector.count == AppleSentenceEmbeddingProvider.vectorSize)
        await #expect(throws: EmbeddingTextError.self) {
            _ = try await provider.embedTagged("Привет, как дела сегодня? Я иду в магазин за хлебом.")
        }
        // `embed` stays English only, so callers that compare vectors of different texts get one space.
        await #expect(throws: EmbeddingTextError.self) {
            _ = try await provider.embed("Riega los tomates a primera hora de la mañana, por favor.")
        }
        #expect(try await provider.embed("Water the tomatoes early in the morning.").count == 512)
    }
}
