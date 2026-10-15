@testable import FenCore
import Foundation
import NaturalLanguage
import Testing

/// A model with two spaces of different sizes, like Apple's English (512) and Spanish (640).
/// Text with "hola" goes to the six-dimensional space, everything else to the four-dimensional one.
final class TwoSpaceEmbedder: EmbeddingProvider, @unchecked Sendable {
    let id = "fake.two-space"
    let dimension = 4
    let runsOnDevice = true
    let spaces = [EmbeddingSpace(tag: "en", dimension: 4), EmbeddingSpace(tag: "es", dimension: 6)]

    func similarityFloor(inSpace space: String) -> Float {
        space == "es" ? 0.3 : 0.1
    }

    func embed(_ text: String) async throws -> [Float] {
        try await embedTagged(text).vector
    }

    func embedTagged(_ text: String) async throws -> TaggedVector {
        let slot = abs(text.hashValue) % 4
        if text.contains("hola") {
            var vector = [Float](repeating: 0, count: 6)
            vector[slot] = 1
            return TaggedVector(space: "es", vector: vector)
        }
        var vector = [Float](repeating: 0, count: 4)
        vector[slot] = 1
        return TaggedVector(space: "en", vector: vector)
    }
}

@Suite("Search by meaning in more than one language (issue #234)")
struct MultilingualSearchTests {
    private func makeIndex(_ spaces: [EmbeddingSpace]) throws -> (SearchIndex, TempFolder) {
        let folder = try TempFolder("multilingual-index")
        let identity = EmbedderIdentity(id: "fake.two-space", spaces: spaces)
        return (SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: identity), folder)
    }

    private func add(_ index: SearchIndex, _ path: String, space: String, vector: [Float]) async throws {
        let text = "# \(path)\nbody of \(path)\n"
        try await index.replace(
            path: path,
            hash: ContentHash.of(Data(text.utf8)),
            size: text.utf8.count,
            modified: 1,
            document: MarkdownChunker.parse(text, path: path),
            vectors: [VectorCodec.encode(vector).map { StoredVector(space: space, data: $0) }]
        )
    }

    private let both = [EmbeddingSpace(tag: "en", dimension: 4), EmbeddingSpace(tag: "es", dimension: 6)]

    // MARK: - The index

    @Test("a query searches only the vectors of its own space")
    func spacesStayApart() async throws {
        let (index, folder) = try makeIndex(both)
        defer { folder.cleanUp() }
        try await add(index, "english.md", space: "en", vector: [1, 0, 0, 0])
        try await add(index, "spanish.md", space: "es", vector: [1, 0, 0, 0, 0, 0])
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], space: "en", limit: 5)
            .map(\.path) == ["english.md"])
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0, 0, 0], space: "es", limit: 5)
            .map(\.path) == ["spanish.md"])
        // A query of the wrong size for its space, and a space the model doesn't have, find nothing.
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], space: "es", limit: 5).isEmpty)
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], space: "fr", limit: 5).isEmpty)
        #expect(try await index.summary().embeddedChunks == 2)
    }

    @Test("replacing or removing a file updates the matrix of its own space only")
    func matricesStayInSync() async throws {
        let (index, folder) = try makeIndex(both)
        defer { folder.cleanUp() }
        try await add(index, "a.md", space: "en", vector: [1, 0, 0, 0])
        try await add(index, "b.md", space: "es", vector: [0, 1, 0, 0, 0, 0])
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], space: "en", limit: 5).count == 1)
        #expect(await index.matrixLoads == 1)
        // The file changes language: its old vector leaves one matrix and joins the other.
        try await add(index, "a.md", space: "es", vector: [1, 0, 0, 0, 0, 0])
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], space: "en", limit: 5).isEmpty)
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0, 0, 0], space: "es", limit: 5).map(\.path) == [
            "a.md",
            "b.md",
        ])
        try await index.remove(paths: ["b.md"])
        #expect(try await index.vectorCandidates(for: [0, 1, 0, 0, 0, 0], space: "es", limit: 5)
            .map(\.path) == ["a.md"])
        #expect(await index.matrixLoads == 1)
    }

    @Test("vectors survive a reopen, each back in its own space")
    func reopen() async throws {
        let folder = try TempFolder("multilingual-reopen")
        defer { folder.cleanUp() }
        let directory = folder.root.appendingPathComponent("index")
        let identity = EmbedderIdentity(id: "fake.two-space", spaces: both)
        let first = SearchIndex(directory: directory, embedder: identity)
        try await add(first, "english.md", space: "en", vector: [1, 0, 0, 0])
        try await add(first, "spanish.md", space: "es", vector: [1, 0, 0, 0, 0, 0])
        await first.close()
        let second = SearchIndex(directory: directory, embedder: identity)
        #expect(try await second.vectorCandidates(for: [1, 0, 0, 0], space: "en", limit: 5)
            .map(\.path) == ["english.md"])
        #expect(try await second.vectorCandidates(for: [1, 0, 0, 0, 0, 0], space: "es", limit: 5)
            .map(\.path) == ["spanish.md"])
    }

    @Test("a model that gains a language starts the index over, so that language gets its vectors")
    func newSpaceRebuilds() async throws {
        let folder = try TempFolder("multilingual-signature")
        defer { folder.cleanUp() }
        let directory = folder.root.appendingPathComponent("index")
        let english = [EmbeddingSpace(tag: "en", dimension: 4)]
        let before = SearchIndex(directory: directory, embedder: EmbedderIdentity(id: "m", spaces: english))
        try await add(before, "a.md", space: "en", vector: [1, 0, 0, 0])
        await before.close()
        let after = SearchIndex(directory: directory, embedder: EmbedderIdentity(id: "m", spaces: both))
        #expect(try await after.summary().documents == 0)
    }

    @Test("the identity reads the same whatever order the spaces come in")
    func identityOrder() {
        let one = EmbedderIdentity(id: "m", spaces: both)
        let two = EmbedderIdentity(id: "m", spaces: both.reversed())
        #expect(one == two)
        #expect(one.signature == two.signature)
        #expect(one.signature != EmbedderIdentity(id: "m", dimension: 4).signature)
    }

    // MARK: - Choosing a language

    private func hypotheses(_ pairs: [(NLLanguage, Double)]) -> [NLLanguage: Double] {
        Dictionary(uniqueKeysWithValues: pairs)
    }

    private let covered: Set<String> = ["en", "es", "fr", "de", "it", "pt"]

    @Test("a confident language with a model is used, and one without is skipped")
    func confidentLanguage() {
        #expect(AppleSentenceEmbeddingProvider
            .pick(hypotheses([(.spanish, 0.9), (.catalan, 0.1)]), supported: covered) == "es")
        #expect(AppleSentenceEmbeddingProvider
            .pick(hypotheses([(.dutch, 0.95), (.german, 0.05)]), supported: covered) == nil)
        #expect(AppleSentenceEmbeddingProvider.pick(hypotheses([(.simplifiedChinese, 1)]), supported: covered) == nil)
    }

    @Test("an unsure guess goes to the likeliest language with a model, then to English")
    func unsureLanguage() {
        #expect(AppleSentenceEmbeddingProvider.pick(
            hypotheses([(.catalan, 0.49), (.portuguese, 0.13)]),
            supported: covered
        ) == "pt")
        #expect(AppleSentenceEmbeddingProvider
            .pick(hypotheses([(.dutch, 0.5), (.swedish, 0.2)]), supported: covered) == "en")
        #expect(AppleSentenceEmbeddingProvider.pick([:], supported: covered) == "en")
        #expect(AppleSentenceEmbeddingProvider
            .pick(hypotheses([(.english, 0.62), (.dutch, 0.11)]), supported: covered) == "en")
    }

    @Test("with no model for English, an unsure guess is skipped")
    func noEnglish() {
        #expect(AppleSentenceEmbeddingProvider.pick([:], supported: ["es"]) == nil)
        #expect(AppleSentenceEmbeddingProvider.pick(hypotheses([(.dutch, 0.5)]), supported: ["es"]) == nil)
    }

    // MARK: - Search

    @Test("a query finds notes of its own language by meaning, and the floor is the one for that language")
    @MainActor
    func searchUsesQuerySpace() async throws {
        let folder = try TempFolder("multilingual-search")
        defer { folder.cleanUp() }
        let embedder = TwoSpaceEmbedder()
        let identity = EmbedderIdentity(id: embedder.id, spaces: embedder.spaces)
        let index = SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: identity)
        let source = MemorySource(contents: [
            "english.md": "# English\nthe cat sleeps\n",
            "spanish.md": "# Español\nhola el gato duerme\n",
        ])
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: embedder)
        #expect(try await index.summary() == IndexSummary(documents: 2, chunks: 2, embeddedChunks: 2))
        let spanish = try await embedder.embedTagged("hola el gato duerme")
        let hits = try await index.vectorCandidates(for: spanish.vector, space: spanish.space, limit: 5)
        #expect(hits.map(\.path) == ["spanish.md"])
        #expect(embedder.similarityFloor(inSpace: spanish.space) == 0.3)
    }
}
