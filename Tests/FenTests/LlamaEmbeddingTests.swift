@testable import FenCore
import Foundation
import Testing

/// Runs the real downloaded models. Set `FEN_MODEL_DIR` to a folder that holds the catalog files
/// (the same file names the app uses). Without it these tests skip, and CI does not download
/// gigabytes.
enum DownloadedModels {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["FEN_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func file(for model: ModelDescriptor) -> URL? {
        guard let url = directory?.appendingPathComponent(model.fileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

@Suite("Embeddings from a downloaded model (issue #234)", .serialized)
struct LlamaEmbeddingTests {
    private func provider(_ model: ModelDescriptor) throws -> LlamaEmbeddingProvider {
        let file = try #require(DownloadedModels.file(for: model), "\(model.fileName) is not in FEN_MODEL_DIR")
        return try #require(LlamaEmbeddingProvider(model: model, file: file))
    }

    private func cosine(_ one: [Float], _ two: [Float]) -> Float {
        zip(one, two).reduce(0) { $0 + $1.0 * $1.1 }
    }

    @Test(
        "a query is closer to the note that answers it, and the vectors have unit length",
        .enabled(if: DownloadedModels.directory != nil),
        arguments: [ModelCatalog.embeddingGemma2, ModelCatalog.qwen3Embedding]
    )
    func smoke(model: ModelDescriptor) async throws {
        guard DownloadedModels.file(for: model) != nil else { return }
        let embedder = try provider(model)
        let bike = try await embedder.embed("# Bike repair\nThe rear tire has a slow leak. Patch the inner tube.")
        let tax = try await embedder.embed("# Taxes\nFile the return before April and keep every receipt.")
        let query = try await embedder.embedQueryTagged("flat tyre on my bicycle")
        #expect(bike.count == model.embeddingDimension)
        #expect(query.vector.count == model.embeddingDimension)
        #expect(abs(cosine(bike, bike) - 1) < 0.001)
        #expect(cosine(query.vector, bike) > cosine(query.vector, tax))
    }
}

/// Quality of the downloaded embedding models on the same hand-labeled sets as Apple's
/// (`QualityCorpus`, `MultilingualCorpus`), plus the thing Apple's models can't do: finding a
/// note written in another language. Set `FEN_SPIKE=1` to print the numbers that
/// `docs/spikes/embedding-model.md` quotes.
@Suite("Quality of downloaded embedding models (issue #234)", .serialized)
struct LlamaQualityTests {
    private let spike = ProcessInfo.processInfo.environment["FEN_SPIKE"] != nil
    private static let sets: [(tag: String, documents: [String: String], queries: [(String, String)])] =
        [("en", QualityCorpus.documents, QualityCorpus.queries)]
            + MultilingualCorpus.all.map { ($0.tag, $0.documents, $0.queries) }
    private static let dutch = [
        "nl/fiets.md": "# Fiets repareren\nDe achterband loopt langzaam leeg. Plak de binnenband en controleer de remblokken.",
    ]

    private struct Scores {
        var reciprocalRank = 0.0
        var top3 = 0
    }

    private func score(_ ranked: [String], answers: Set<String>, into scores: inout Scores) {
        guard let position = ranked.firstIndex(where: answers.contains) else { return }
        scores.reciprocalRank += 1 / Double(position + 1)
        scores.top3 += position < 3 ? 1 : 0
    }

    /// One workspace holding every language, one folder per language.
    private func buildIndex(
        _ embedder: LlamaEmbeddingProvider,
        in folder: TempFolder
    ) async throws -> SearchIndex {
        var documents = Self.dutch
        for set in Self.sets {
            for (name, text) in set.documents {
                documents["\(set.tag)/\(name)"] = text
            }
        }
        let identity = EmbedderIdentity(id: embedder.id, spaces: embedder.spaces)
        let index = SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: identity)
        let source = MemorySource(contents: documents)
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: embedder)
        return index
    }

    @Test(
        "every language is found by meaning in a workspace that mixes them, and across languages",
        .enabled(if: DownloadedModels.directory != nil),
        arguments: [ModelCatalog.embeddingGemma2, ModelCatalog.qwen3Embedding]
    )
    func mixedWorkspace(model: ModelDescriptor) async throws {
        guard let file = DownloadedModels.file(for: model) else { return }
        let embedder = try #require(LlamaEmbeddingProvider(model: model, file: file))
        let folder = try TempFolder("llama-quality")
        defer { folder.cleanUp() }
        let index = try await buildIndex(embedder, in: folder)
        let languages = Self.sets.map(\.tag)

        func search(
            _ query: String,
            floor: Float
        ) async throws -> (text: [VectorCandidate], meaning: [VectorCandidate]) {
            let tagged = try await embedder.embedQueryTagged(query)
            let unit = try #require(VectorCodec.normalized(tagged.vector))
            let found = try await index.vectorCandidates(for: unit, space: tagged.space, limit: 100)
            return ([], found.filter { $0.score >= Double(floor) })
        }

        // 1. Same language: the answer is the note of the query's own language.
        for floor: Float in spike ? [0.2, 0.3, 0.5, 0.6, 0.65, 0.7, 0.72] : [] {
            var own = Scores(), any = Scores(), crossRecall = 0.0, count = 0.0
            for set in Self.sets {
                for (query, answer) in set.queries {
                    let meaning = try await search(query, floor: floor).meaning
                    score(meaning.map(\.path), answers: ["\(set.tag)/\(answer)"], into: &own)
                    score(meaning.map(\.path), answers: Set(languages.map { "\($0)/\(answer)" }), into: &any)
                    let top = Set(meaning.prefix(languages.count).map(\.path))
                    crossRecall += Double(languages.filter { top.contains("\($0)/\(answer)") }.count) /
                        Double(languages.count)
                    count += 1
                }
            }
            print("QUALITY \(model.id) floor \(floor): own-language MRR \(own.reciprocalRank / count) top3 \(own.top3)"
                + " | any-language MRR \(any.reciprocalRank / count) top3 \(any.top3)"
                + " | cross-language recall@6 \(crossRecall / count) of \(Int(count)) queries")
        }

        if spike {
            // Where right and wrong answers sit, to pick the floor.
            var right: [Float] = [], wrong: [Float] = []
            for set in Self.sets {
                for (query, answer) in set.queries {
                    for hit in try await search(query, floor: 0).meaning where hit.path.hasPrefix("\(set.tag)/") {
                        if hit.path == "\(set.tag)/\(answer)" {
                            right.append(Float(hit.score))
                        } else {
                            wrong.append(Float(hit.score))
                        }
                    }
                }
            }
            right.sort()
            wrong.sort()
            let pick: ([Float], Double) -> Float = { $0[min($0.count - 1, Int(Double($0.count) * $1))] }
            print(
                "QUALITY \(model.id) cosine right p10 \(pick(right, 0.1)) p25 \(pick(right, 0.25)) median \(pick(right, 0.5))"
                    +
                    " | wrong median \(pick(wrong, 0.5)) p90 \(pick(wrong, 0.9)) p99 \(pick(wrong, 0.99)) max \(wrong.last ?? 0)"
            )
        }

        // 2. At the chosen floor.
        let floor = embedder.similarityFloor
        var perLanguage: [String: Scores] = [:]
        var anyLanguage = Scores()
        var total = 0.0
        for set in Self.sets {
            var scores = Scores()
            for (query, answer) in set.queries {
                let meaning = try await search(query, floor: floor).meaning
                score(meaning.map(\.path), answers: ["\(set.tag)/\(answer)"], into: &scores)
                score(meaning.map(\.path), answers: Set(languages.map { "\($0)/\(answer)" }), into: &anyLanguage)
                total += 1
            }
            perLanguage[set.tag] = scores
            if spike {
                print(
                    "QUALITY \(model.id) \(set.tag) at floor \(floor): MRR \(scores.reciprocalRank / Double(set.queries.count))"
                        + " top3 \(scores.top3) of \(set.queries.count)"
                )
            }
        }
        for (tag, scores) in perLanguage {
            let count = Double(Self.sets.first { $0.tag == tag }?.queries.count ?? 1)
            #expect(scores.reciprocalRank / count >= 0.45, "\(model.id) \(tag)")
        }
        #expect(anyLanguage.reciprocalRank / total >= 0.6)

        // 3. A language Apple has no model for: a Dutch note found by an English and a Spanish query.
        for query in ["flat tyre on my bicycle", "tengo un neumático desinflado", "lekke band"] {
            let meaning = try await search(query, floor: floor).meaning
            let ranked = meaning.map(\.path)
            if spike {
                print(
                    "QUALITY \(model.id) Dutch note for \"\(query)\": rank \(ranked.firstIndex(of: "nl/fiets.md").map { $0 + 1 } ?? 0)"
                )
            }
            #expect(ranked.prefix(8).contains("nl/fiets.md"), "\(model.id): \(query)")
        }
    }
}
