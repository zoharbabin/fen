@testable import FenCore
import Foundation
import Testing

@Suite("SearchIndex")
struct SearchIndexTests {
    private func makeIndex(embedder: EmbedderIdentity? = nil) throws -> (SearchIndex, TempFolder) {
        let folder = try TempFolder("index")
        return (SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: embedder), folder)
    }

    private func add(_ index: SearchIndex, _ path: String, _ text: String, vectors: [Data?] = []) async throws {
        try await index.replace(
            path: path,
            hash: ContentHash.of(Data(text.utf8)),
            size: text.utf8.count,
            modified: 1,
            document: MarkdownChunker.parse(text, path: path),
            vectors: vectors.map { $0.map { StoredVector(space: EmbeddingSpace.single, data: $0) } }
        )
    }

    @Test("finds words in any chunk, with the file, heading and a snippet")
    func fullText() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        try await add(index, "a.md", "# Cooking\n## Bread\nKnead the dough for ten minutes.\n")
        try await add(index, "b.md", "# Cars\nThe engine needs oil.\n")
        let hits = try await index.textCandidates(matching: "dough", limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].path == "a.md")
        #expect(hits[0].heading == "Cooking > Bread")
        #expect(hits[0].snippet.contains("dough"))
        #expect(hits[0].startLine == 3)
    }

    @Test("matches word forms, prefixes of the last word, file names, and headings")
    func lenientMatching() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        try await add(index, "notes/budgeting.md", "# Quarterly plan\nWe are running the numbers.\n")
        #expect(try await index.textCandidates(matching: "run number", limit: 5).count == 1)
        #expect(try await index.textCandidates(matching: "quart", limit: 5).count == 1)
        #expect(try await index.textCandidates(matching: "budgeting", limit: 5).count == 1)
        #expect(try await index.textCandidates(matching: "Quarterly PLAN", limit: 5).count == 1)
    }

    @Test("a question falls back from all words to any word")
    func looseFallback() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        try await add(index, "a.md", "# Release\nSign and notarize the build before publishing.\n")
        let hits = try await index.textCandidates(matching: "how do I sign the app bundle", limit: 5)
        #expect(hits.first?.path == "a.md")
    }

    @Test("query text can never be a syntax error or an operator")
    func hostileQueries() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        try await add(index, "a.md", "# Title\nplain words here\n")
        for query in [
            "\"",
            "\"\"\"",
            "AND",
            "OR NOT",
            "a AND",
            "(",
            "* *",
            "NEAR(a b)",
            "col:val",
            "-x",
            "'; DROP TABLE docs;--",
            "🙂",
            "   ",
            "",
        ] {
            _ = try await index.textCandidates(matching: query, limit: 5)
        }
        #expect(try await index.summary().documents == 1)
        #expect(try await index.textCandidates(matching: "NOT", limit: 5).isEmpty)
    }

    @Test("replacing a file drops its old words, and removing a file drops everything")
    func replaceAndRemove() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        try await add(index, "a.md", "# A\nalpha\n")
        try await add(index, "a.md", "# A\nbeta\n")
        #expect(try await index.textCandidates(matching: "alpha", limit: 5).isEmpty)
        #expect(try await index.textCandidates(matching: "beta", limit: 5).count == 1)
        try await index.remove(paths: ["a.md"])
        #expect(try await index.textCandidates(matching: "beta", limit: 5).isEmpty)
        #expect(try await index.summary() == IndexSummary())
        #expect(try await index.knownDocuments().isEmpty)
    }

    @Test("known documents carry the hash, size and time for the skip check")
    func known() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        try await add(index, "a.md", "# A\nalpha\n")
        let known = try await index.knownDocuments()
        #expect(known["a.md"] == KnownDocument(hash: ContentHash.of(Data("# A\nalpha\n".utf8)), size: 10, modified: 1))
        try await index.touch(path: "a.md", modified: 99)
        #expect(try await index.knownDocuments()["a.md"]?.modified == 99)
    }

    @Test("inbound links count each linking file once, for paths and wiki names")
    func inbound() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        try await add(index, "docs/target.md", "# Target\nneedle\n")
        try await add(index, "docs/one.md", "# One\nSee [t](target.md) and [again](target.md#x).\n")
        try await add(index, "two.md", "# Two\nSee [[Target]] and [t](docs/target.md).\n")
        try await add(index, "self.md", "# Self\n[me](self.md)\n")
        try await index.refreshInbound()
        let hits = try await index.textCandidates(matching: "needle", limit: 5)
        #expect(hits.first?.inbound == 2)
        let selfHits = try await index.textCandidates(matching: "me", limit: 5)
        #expect(selfHits.allSatisfy { $0.path != "self.md" || $0.inbound == 0 })
    }

    @Test("vectors come back by cosine, and only for the embedder that made them")
    func vectors() async throws {
        let identity = EmbedderIdentity(id: "t", dimension: 4)
        let (index, folder) = try makeIndex(embedder: identity)
        defer { folder.cleanUp() }
        try await add(index, "x.md", "# X\nfirst\n", vectors: [VectorCodec.encode([1, 0, 0, 0])])
        try await add(index, "y.md", "# Y\nsecond\n", vectors: [VectorCodec.encode([0, 1, 0, 0])])
        let hits = try await index.vectorCandidates(for: [0.9, 0.1, 0, 0].normalizedForTest, limit: 5)
        #expect(hits.map(\.path) == ["x.md", "y.md"])
        #expect(hits[0].score > 0.95)
        #expect(try await index.summary().embeddedChunks == 2)
        #expect(try await index.vectorCandidates(for: [1, 0], limit: 5).isEmpty)
        try await index.remove(paths: ["x.md"])
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], limit: 5).map(\.path) == ["y.md"])
    }

    @Test("scores are cosines even when the query vector is not unit length")
    func cosineScoresForRawQueries() async throws {
        let identity = EmbedderIdentity(id: "t", dimension: 4)
        let (index, folder) = try makeIndex(embedder: identity)
        defer { folder.cleanUp() }
        try await add(index, "x.md", "# X\nfirst\n", vectors: [VectorCodec.encode([1, 0, 0, 0])])
        let hits = try await index.vectorCandidates(for: [9, 0, 0, 0], limit: 5)
        #expect(hits.first.map { abs($0.score - 1) < 0.02 } == true)
        #expect(try await index.vectorCandidates(for: [0, 0, 0, 0], limit: 5).isEmpty)
        #expect(try await index.vectorCandidates(for: [.nan, 0, 0, 0], limit: 5).isEmpty)
    }

    @Test("a different embedder starts the index over, so old vectors are never mixed in")
    func embedderChange() async throws {
        let folder = try TempFolder("index-signature")
        defer { folder.cleanUp() }
        let directory = folder.root.appendingPathComponent("index")
        let first = SearchIndex(directory: directory, embedder: EmbedderIdentity(id: "one", dimension: 4))
        try await add(first, "a.md", "# A\nalpha\n", vectors: [VectorCodec.encode([1, 0, 0, 0])])
        await first.close()
        let same = SearchIndex(directory: directory, embedder: EmbedderIdentity(id: "one", dimension: 4))
        #expect(try await same.summary().documents == 1)
        await same.close()
        let other = SearchIndex(directory: directory, embedder: EmbedderIdentity(id: "two", dimension: 8))
        #expect(try await other.summary().documents == 0)
        let none = SearchIndex(directory: directory, embedder: nil)
        #expect(try await none.summary().documents == 0)
    }

    @Test("a damaged file is replaced instead of failing every search")
    func corruption() async throws {
        let folder = try TempFolder("index-corrupt")
        defer { folder.cleanUp() }
        let directory = folder.root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: directory.appendingPathComponent(SearchIndex.fileName))
        let index = SearchIndex(directory: directory, embedder: nil)
        try await add(index, "a.md", "# A\nalpha\n")
        #expect(try await index.textCandidates(matching: "alpha", limit: 5).count == 1)
    }

    @Test("stale -wal and -shm files next to a damaged index do not break the rebuild")
    func corruptionClearsSidecars() async throws {
        let folder = try TempFolder("index-corrupt-wal")
        defer { folder.cleanUp() }
        let directory = folder.root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(SearchIndex.fileName)
        try Data(repeating: 0x41, count: 4096).write(to: file)
        for suffix in ["-wal", "-shm"] {
            try Data(repeating: 0x42, count: 8192).write(to: URL(fileURLWithPath: file.path + suffix))
        }
        let index = SearchIndex(directory: directory, embedder: nil)
        try await add(index, "a.md", "# A\nalpha\n")
        #expect(try await index.textCandidates(matching: "alpha", limit: 5).count == 1)
    }

    @Test("pieces of one long line get their own ids, and each id returns its own text")
    func chunkLookupIsUnique() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        let line = (0 ..< 600).map { "token\($0)x" }.joined(separator: " ")
        try await add(index, "long.md", "# Long\n" + line + "\n")
        let first = try #require(try await index.textCandidates(matching: "token0x", limit: 5).first)
        let last = try #require(try await index.textCandidates(matching: "token599x", limit: 5).first)
        #expect(first.startLine == last.startLine)
        #expect(first.chunkID != last.chunkID)
        #expect(try await index.chunkText(path: "long.md", chunkID: first.chunkID)?.contains("token0x") == true)
        #expect(try await index.chunkText(path: "long.md", chunkID: last.chunkID)?.contains("token599x") == true)
        #expect(try await index.chunkText(path: "other.md", chunkID: last.chunkID) == nil)
    }

    @Test("saving a file keeps the vectors in memory, and the next search does not read them back")
    func matrixSurvivesWrites() async throws {
        let identity = EmbedderIdentity(id: "t", dimension: 4)
        let (index, folder) = try makeIndex(embedder: identity)
        defer { folder.cleanUp() }
        try await add(index, "x.md", "# X\nfirst\n", vectors: [VectorCodec.encode([1, 0, 0, 0])])
        try await add(index, "y.md", "# Y\nsecond\n", vectors: [VectorCodec.encode([0, 1, 0, 0])])
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], limit: 5).map(\.path) == ["x.md", "y.md"])
        #expect(await index.matrixLoads == 1)

        // The same content again, a text-only edit, and an edit with a new vector.
        try await add(index, "x.md", "# X\nfirst\n", vectors: [VectorCodec.encode([1, 0, 0, 0])])
        try await add(index, "y.md", "# Y\nsecond edited\n", vectors: [VectorCodec.encode([0, 1, 0, 0])])
        try await add(index, "x.md", "# X\nfirst moved\n", vectors: [VectorCodec.encode([0, 0, 1, 0])])
        try await add(index, "z.md", "# Z\nno vector\n")
        #expect(try await index.vectorCandidates(for: [0, 0, 1, 0], limit: 1).map(\.path) == ["x.md"])
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], limit: 5).count == 2)
        try await index.remove(paths: ["x.md"])
        #expect(try await index.vectorCandidates(for: [1, 0, 0, 0], limit: 5).map(\.path) == ["y.md"])
        #expect(await index.matrixLoads == 1)
    }

    @Test("a save that leaves the links alone keeps inbound counts, and a changed link updates them")
    func inboundOnlyRefreshesForLinkChanges() async throws {
        let (index, folder) = try makeIndex()
        defer { folder.cleanUp() }
        try await add(index, "target.md", "# Target\nneedle\n")
        try await add(index, "one.md", "# One\nSee [t](target.md).\n")
        try await index.refreshInbound()
        func inbound() async throws -> Int? {
            try await index.textCandidates(matching: "needle", limit: 5).first?.inbound
        }
        #expect(try await inbound() == 1)

        try await add(index, "target.md", "# Target\nneedle again\n")
        try await add(index, "one.md", "# One\nSee [t](target.md) twice.\n")
        try await index.refreshInbound()
        #expect(try await inbound() == 1)

        try await add(index, "one.md", "# One\nNo link now.\n")
        try await index.refreshInbound()
        #expect(try await inbound() == 0)

        try await add(index, "new.md", "# New\nSee [[Target]].\n")
        try await index.refreshInbound()
        #expect(try await inbound() == 1)

        try await index.remove(paths: ["new.md"])
        try await index.refreshInbound()
        #expect(try await inbound() == 0)
    }

    @Test("after markClosed nothing runs and nothing is created on disk")
    func closed() async throws {
        let folder = try TempFolder("index-closed")
        defer { folder.cleanUp() }
        let directory = folder.root.appendingPathComponent("index")
        let index = SearchIndex(directory: directory, embedder: nil)
        index.markClosed()
        await #expect(throws: SearchIndexError.self) { try await index.summary() }
        await #expect(throws: SearchIndexError.self) { try await add(index, "a.md", "# A\n") }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("nothing is created until the first write or read")
    func lazy() throws {
        let folder = try TempFolder("index-lazy")
        defer { folder.cleanUp() }
        let directory = folder.root.appendingPathComponent("index")
        _ = SearchIndex(directory: directory, embedder: nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

extension [Float] {
    var normalizedForTest: [Float] {
        VectorCodec.normalized(self) ?? self
    }
}
