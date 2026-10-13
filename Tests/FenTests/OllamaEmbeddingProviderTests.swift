@testable import FenCore
import Foundation
import Testing

@Suite("Ollama embedding provider (issue #35)", .serialized)
struct OllamaEmbeddingProviderTests {
    private func reply(_ vector: [Float]) -> LoopbackServer.Response {
        let numbers = vector.map { String($0) }.joined(separator: ",")
        return LoopbackServer.Response(chunks: [Data(#"{"embeddings":[[\#(numbers)]]}"#.utf8)])
    }

    @Test("refuses an address that is not on this Mac")
    func refusesRemote() {
        #expect(throws: AIError.notLoopback(host: "example.com")) {
            try OllamaEmbeddingProvider(address: "https://example.com")
        }
        #expect(throws: AIError.notLoopback(host: "192.168.1.5")) {
            try OllamaEmbeddingProvider(address: "http://192.168.1.5:11434")
        }
    }

    @Test("sends the model and the text to /api/embed and returns the vector")
    func embeds() async throws {
        let server = try await LoopbackServer.start { _ in reply([0.5, -0.25, 1]) }
        defer { server.stop() }
        let provider = try OllamaEmbeddingProvider(address: server.baseURL, model: "tiny", dimension: 3)
        let vector = try await provider.embed("hello")
        #expect(vector == [0.5, -0.25, 1])
        #expect(provider.id == "ollama.tiny")
        let request = try #require(server.requests.first)
        #expect(request.path == "/api/embed")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "tiny")
        #expect(body["input"] as? String == "hello")
    }

    @Test("a vector of the wrong size is refused, so it never reaches the index")
    func wrongSize() async throws {
        let server = try await LoopbackServer.start { _ in reply([1, 2]) }
        defer { server.stop() }
        let provider = try OllamaEmbeddingProvider(address: server.baseURL, dimension: 3)
        await #expect(throws: EmbeddingTextError.self) { try await provider.embed("x") }
    }

    @Test("an error status gives no vector")
    func errorStatus() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response(status: 404) }
        defer { server.stop() }
        let provider = try OllamaEmbeddingProvider(address: server.baseURL)
        await #expect(throws: EmbeddingTextError.self) { try await provider.embed("x") }
    }

    @Test("is available only when Ollama has the model")
    func availability() async throws {
        let have = try await LoopbackServer.start { _ in LoopbackServer.Response() }
        defer { have.stop() }
        #expect(try OllamaEmbeddingProvider(address: have.baseURL).isAvailable)
        let missing = try await LoopbackServer.start { _ in LoopbackServer.Response(status: 404) }
        defer { missing.stop() }
        #expect(try !OllamaEmbeddingProvider(address: missing.baseURL).isAvailable)
        #expect(try !OllamaEmbeddingProvider(address: "http://localhost:1").isAvailable)
        #expect(have.requests.first?.path == "/api/show")
    }

    /// Needs Ollama on this Mac with `embeddinggemma` pulled. Run: `FEN_LIVE_OLLAMA=1 swift test --filter
    /// OllamaEmbedding`.
    @Test(
        "live: EmbeddingGemma ranks the hand-labeled queries, and meaning and hybrid beat words alone",
        .enabled(if: ProcessInfo.processInfo.environment["FEN_LIVE_OLLAMA"] != nil)
    )
    func liveQuality() async throws {
        let provider = try OllamaEmbeddingProvider()
        try #require(provider.isAvailable, "Ollama isn't running or embeddinggemma isn't pulled.")
        let folder = try TempFolder("ollama-quality")
        defer { folder.cleanUp() }
        let identity = EmbedderIdentity(id: provider.id, dimension: provider.dimension)
        let index = SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: identity)
        let source = MemorySource(contents: QualityCorpus.documents)
        let start = ContinuousClock.now
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: provider)
        print("OLLAMA index+embed per document \((ContinuousClock.now - start) / QualityCorpus.documents.count)")
        let summary = try await index.summary()
        #expect(summary.embeddedChunks == summary.chunks)

        let workspace = UUID()
        let count = Double(QualityCorpus.queries.count)
        var results: [Float: (words: Double, meaning: Double, hybrid: Double)] = [:]
        var right: [Float] = [], wrong: [Float] = []
        for floor: Float in [0, 0.2, 0.3, 0.35, 0.4, 0.5] {
            var words = 0.0, meaning = 0.0, hybrid = 0.0
            for (query, answer) in QualityCorpus.queries {
                let text = try await index.textCandidates(matching: query, limit: 50)
                let vector = try await index.vectorCandidates(for: provider.embed(query), limit: 50)
                func rr(_ ranked: [String]) -> Double {
                    ranked.firstIndex(of: answer).map { 1 / Double($0 + 1) } ?? 0
                }
                words += rr(text.map(\.path))
                meaning += rr(vector.filter { $0.score >= Double(floor) }.map(\.path))
                let fused = HybridRanker.rank(
                    [WorkspaceCandidates(workspaceID: workspace, workspaceName: "w", text: text, vector: vector)],
                    similarityFloor: floor, origin: nil, limit: 10
                )
                hybrid += rr(fused.map(\.relativePath))
                if floor == 0 {
                    for hit in vector {
                        if hit.path == answer {
                            right.append(Float(hit.score))
                        } else {
                            wrong.append(Float(hit.score))
                        }
                    }
                }
            }
            results[floor] = (words / count, meaning / count, hybrid / count)
            print(
                "OLLAMA floor \(floor) words MRR \(words / count) meaning MRR \(meaning / count) hybrid MRR \(hybrid / count)"
            )
        }
        right.sort()
        wrong.sort()
        print(
            "OLLAMA right min \(right[0]) median \(right[right.count / 2])"
                + " | wrong median \(wrong[wrong.count / 2]) p90 \(wrong[wrong.count * 9 / 10]) max \(wrong.last ?? 0)"
        )
        let chosen = try #require(results[provider.similarityFloor])
        #expect(chosen.hybrid > chosen.words)
        #expect(chosen.meaning > 0.9)
    }
}
