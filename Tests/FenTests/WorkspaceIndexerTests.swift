@testable import FenCore
import Foundation
import Testing

@Suite("WorkspaceIndexer")
struct WorkspaceIndexerTests {
    private func makeIndex(_ embedder: EmbedderIdentity?) throws -> (SearchIndex, TempFolder) {
        let folder = try TempFolder("indexer")
        return (SearchIndex(directory: folder.root.appendingPathComponent("index"), embedder: embedder), folder)
    }

    private let identity = EmbedderIdentity(id: "fake.concepts", dimension: 64)

    @Test("the first run indexes every file, and a second run reads nothing and embeds nothing")
    func incremental() async throws {
        let (index, folder) = try makeIndex(identity)
        defer { folder.cleanUp() }
        let embedder = FakeEmbedder()
        let source = MemorySource(contents: ["a.md": "# A\nalpha\n", "b.md": "# B\n## Part\nbeta\n"])
        let first = try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files(),
            embedder: embedder
        )
        #expect(first.indexed == 2)
        let embeddedOnce = embedder.calls
        #expect(embeddedOnce == 2)
        let second = try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files(),
            embedder: embedder
        )
        #expect(second.indexed == 0)
        #expect(second.unchanged == 2)
        #expect(embedder.calls == embeddedOnce)
        #expect(try await index.summary() == IndexSummary(documents: 2, chunks: 2, embeddedChunks: 2))
    }

    @Test("a changed file is indexed again, and only that file is embedded again")
    func changedFile() async throws {
        let (index, folder) = try makeIndex(identity)
        defer { folder.cleanUp() }
        let embedder = FakeEmbedder()
        var source = MemorySource(contents: ["a.md": "# A\nalpha\n", "b.md": "# B\nbeta\n"])
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: embedder)
        source.contents["a.md"] = "# A\ngamma delta\n"
        let files = source.files(modified: Date(timeIntervalSince1970: 2000))
        let run = try await WorkspaceIndexer.run(index: index, source: source, files: files, embedder: embedder)
        #expect(run.indexed == 1)
        #expect(run.unchanged == 1)
        #expect(embedder.calls == 3)
        #expect(try await index.textCandidates(matching: "alpha", limit: 5).isEmpty)
        #expect(try await index.textCandidates(matching: "gamma", limit: 5).count == 1)
    }

    @Test("a newer time stamp with the same bytes only updates the time stamp")
    func sameContent() async throws {
        let (index, folder) = try makeIndex(identity)
        defer { folder.cleanUp() }
        let embedder = FakeEmbedder()
        let source = MemorySource(contents: ["a.md": "# A\nalpha\n"])
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: embedder)
        let touched = source.files(modified: Date(timeIntervalSince1970: 5000))
        let run = try await WorkspaceIndexer.run(index: index, source: source, files: touched, embedder: embedder)
        #expect(run.indexed == 0)
        #expect(embedder.calls == 1)
        #expect(try await index.knownDocuments()["a.md"]?.modified == 5000)
    }

    @Test("a hinted path is checked even when its size and time stamp look the same")
    func hintedPath() async throws {
        let (index, folder) = try makeIndex(nil)
        defer { folder.cleanUp() }
        var source = MemorySource(contents: ["a.md": "# A\nalpha\n"])
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: nil)
        source.contents["a.md"] = "# A\nomega\n"
        let quiet = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: nil)
        #expect(quiet.indexed == 0)
        let hinted = try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files(),
            embedder: nil,
            recheck: ["a.md"]
        )
        #expect(hinted.indexed == 1)
        #expect(try await index.textCandidates(matching: "omega", limit: 5).count == 1)
    }

    @Test("files that left the list are removed, and unreadable files are skipped")
    func removalAndSkips() async throws {
        let (index, folder) = try makeIndex(nil)
        defer { folder.cleanUp() }
        var source = MemorySource(contents: ["a.md": "# A\nalpha\n", "b.md": "# B\nbeta\n"])
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: nil)
        let vanished = WorkspaceFile(relativePath: "ghost.md", size: 5, modified: .distantPast)
        let run = try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files().filter { $0.relativePath == "a.md" } + [vanished],
            embedder: nil
        )
        #expect(run.removed == 1)
        #expect(run.skipped == 1)
        #expect(try await index.knownDocuments().keys.sorted() == ["a.md"])
        source.contents = [:]
        #expect(try await WorkspaceIndexer.run(index: index, source: source, files: [], embedder: nil).removed == 1)
        #expect(try await index.summary() == IndexSummary())
    }

    @Test("front matter is not embedded, the heading trail is, and a failing embedder still leaves words searchable")
    func embeddingInput() async throws {
        let (index, folder) = try makeIndex(identity)
        defer { folder.cleanUp() }
        let embedder = FakeEmbedder()
        let source = MemorySource(contents: [
            "a.md": "---\ntags: [x]\n---\n# Guide\n## Setup\nInstall it.\n",
            "b.md": "# 42\n1234 5678\n",
        ])
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: embedder)
        #expect(embedder.inputs.contains { $0.hasPrefix("Guide > Setup\n") })
        #expect(!embedder.inputs.contains { $0.contains("tags") })
        let summary = try await index.summary()
        #expect(summary.chunks == 3)
        #expect(summary.embeddedChunks == 1)
        #expect(try await index.textCandidates(matching: "5678", limit: 5).count == 1)
    }

    @Test("re-indexing, with or without a change, does not make the next search read all vectors again")
    func matrixKept() async throws {
        let (index, folder) = try makeIndex(identity)
        defer { folder.cleanUp() }
        let embedder = FakeEmbedder()
        var source = MemorySource(contents: ["a.md": "# A\nalpha\n", "b.md": "# B\nbeta [a](a.md)\n"])
        _ = try await WorkspaceIndexer.run(index: index, source: source, files: source.files(), embedder: embedder)
        let query = try await embedder.embed("alpha")
        #expect(try await index.vectorCandidates(for: query, limit: 5).count == 2)
        #expect(await index.matrixLoads == 1)

        let same = try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files(),
            embedder: embedder
        )
        #expect(same.indexed == 0)
        source.contents["a.md"] = "# A\nalpha gamma\n"
        let edited = source.files(modified: Date(timeIntervalSince1970: 2000))
        let run = try await WorkspaceIndexer.run(index: index, source: source, files: edited, embedder: embedder)
        #expect(run.indexed == 1)
        #expect(try await index.vectorCandidates(for: query, limit: 5).count == 2)
        #expect(await index.matrixLoads == 1)
    }

    @Test("a file whose embedding failed is searchable by words and is embedded again on the next run")
    func embedderFailureIsRetried() async throws {
        let (index, folder) = try makeIndex(identity)
        defer { folder.cleanUp() }
        let embedder = FlakyEmbedder()
        let source = MemorySource(contents: ["a.md": "# A\nalpha\n", "b.md": "# B\nbeta\n"])
        embedder.isFailing = true
        let first = try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files(),
            embedder: embedder
        )
        #expect(first.indexed == 2)
        #expect(try await index.summary() == IndexSummary(documents: 2, chunks: 2, embeddedChunks: 0))
        #expect(try await index.textCandidates(matching: "alpha", limit: 5).count == 1)

        // Same bytes, same size, same time stamp. The embedder works now.
        embedder.isFailing = false
        let second = try await WorkspaceIndexer.run(
            index: index, source: source, files: source.files(), embedder: embedder
        )
        #expect(second.indexed == 2)
        #expect(try await index.summary() == IndexSummary(documents: 2, chunks: 2, embeddedChunks: 2))

        let third = try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files(),
            embedder: embedder
        )
        #expect(third.indexed == 0)
        #expect(third.unchanged == 2)
    }

    @Test("a canceled run keeps what it finished, and the next run does only the rest")
    func resume() async throws {
        let (index, folder) = try makeIndex(identity)
        defer { folder.cleanUp() }
        let contents = Dictionary(uniqueKeysWithValues: (0 ..< 60).map { ("n\($0).md", "# N\($0)\nword\($0) text\n") })
        let source = MemorySource(contents: contents)
        let embedder = FakeEmbedder()
        let gate = CancelAfter(calls: 20, embedder: embedder)
        let task = Task { try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files(),
            embedder: gate
        ) }
        gate.task = task
        await #expect(throws: CancellationError.self) { try await task.value }
        let done = try await index.summary().documents
        #expect(done > 0 && done < 60)

        let resumed = try await WorkspaceIndexer.run(
            index: index,
            source: source,
            files: source.files(),
            embedder: embedder
        )
        #expect(resumed.indexed == 60 - done)
        #expect(resumed.unchanged == done)
        #expect(try await index.summary().documents == 60)
    }
}

/// Cancels the running task after some embed calls, to stop an index run in the middle.
final class CancelAfter: EmbeddingProvider, @unchecked Sendable {
    private let inner: FakeEmbedder
    private let limit: Int
    private let lock = NSLock()
    private var stored: Task<IndexRun, any Error>?
    var id: String {
        inner.id
    }

    var dimension: Int {
        inner.dimension
    }

    var runsOnDevice: Bool {
        true
    }

    init(calls: Int, embedder: FakeEmbedder) {
        limit = calls
        inner = embedder
    }

    var task: Task<IndexRun, any Error>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func embed(_ text: String) async throws -> [Float] {
        let vector = try await inner.embed(text)
        if inner.calls >= limit {
            task?.cancel()
        }
        return vector
    }
}

/// An embedder that fails with an error that is not about the text, such as a model that cannot load.
final class FlakyEmbedder: EmbeddingProvider, @unchecked Sendable {
    struct Unavailable: Error {}

    private let inner = FakeEmbedder()
    private let lock = NSLock()
    private var failing = false
    let id = "fake.concepts"
    let dimension = 64
    let runsOnDevice = true

    var isFailing: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func embed(_ text: String) async throws -> [Float] {
        if isFailing {
            throw Unavailable()
        }
        return try await inner.embed(text)
    }
}
