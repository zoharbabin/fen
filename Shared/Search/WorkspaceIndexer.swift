import Foundation

struct IndexRun: Equatable, Sendable {
    var indexed = 0
    var unchanged = 0
    var removed = 0
    /// Files that could not be read, for example because they were deleted mid-run.
    var skipped = 0
}

/// Brings one workspace's index up to date with its file list (issue #35).
///
/// - Only files whose size or time stamp moved are read. Of those, only the ones whose content
///   hash changed are chunked and embedded.
/// - Each file is committed on its own, so a canceled or crashed run keeps its progress and the
///   next run picks up where it stopped.
enum WorkspaceIndexer {
    private static let chunksPerCheckpoint = 25

    static func run(
        index: SearchIndex,
        source: any WorkspaceSource,
        files: [WorkspaceFile],
        embedder: (any EmbeddingProvider)?,
        recheck: Set<String> = [],
        context: JobContext? = nil
    ) async throws -> IndexRun {
        var result = IndexRun()
        let known = try await index.knownDocuments()
        let present = Set(files.map(\.relativePath))

        let gone = known.keys.filter { !present.contains($0) }
        try await index.remove(paths: Array(gone))
        result.removed = gone.count

        let todo = files.filter { file in
            guard let old = known[file.relativePath] else { return true }
            return recheck.contains(file.relativePath) || old.size != file.size
                || old.modified != file.modified.timeIntervalSince1970
                || (embedder != nil && old.hasMissingVectors)
        }
        .sorted(by: WorkspaceFile.isInPathOrder)
        result.unchanged = files.count - todo.count

        for (position, file) in todo.enumerated() {
            try Task.checkCancellation()
            try await context?.checkpoint()
            context?.report(completed: position, total: todo.count)
            let outcome = try await indexFile(
                file,
                known: known[file.relativePath],
                index: index,
                source: source,
                embedder: embedder,
                context: context
            )
            switch outcome {
            case .indexed: result.indexed += 1
            case .unchanged: result.unchanged += 1
            case .skipped: result.skipped += 1
            }
        }
        context?.report(completed: todo.count, total: todo.count)
        try await index.refreshInbound()
        return result
    }

    private enum FileOutcome {
        case indexed
        case unchanged
        case skipped
    }

    private static func indexFile(
        _ file: WorkspaceFile,
        known: KnownDocument?,
        index: SearchIndex,
        source: any WorkspaceSource,
        embedder: (any EmbeddingProvider)?,
        context: JobContext?
    ) async throws -> FileOutcome {
        guard let data = try? source.read(relativePath: file.relativePath) else { return .skipped }
        let hash = ContentHash.of(data)
        let modified = file.modified.timeIntervalSince1970
        if known?.hash == hash {
            try await index.touch(path: file.relativePath, modified: modified)
            return .unchanged
        }
        let document = MarkdownChunker.parse(String(decoding: data, as: UTF8.self), path: file.relativePath)
        var vectors: [StoredVector?] = []
        var embedderFailed = false
        for (number, chunk) in document.chunks.enumerated() {
            if number > 0, number % chunksPerCheckpoint == 0 {
                try await context?.checkpoint()
            }
            do {
                try await vectors.append(vector(for: chunk, title: document.title, embedder: embedder))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                embedderFailed = true
                vectors.append(nil)
            }
        }
        try await index.replace(
            path: file.relativePath,
            hash: embedderFailed ? hash + KnownDocument.missingVectorsMarker : hash,
            size: data.count,
            modified: modified,
            document: document,
            vectors: vectors
        )
        return .indexed
    }

    private static func vector(
        for chunk: DocumentChunk,
        title: String,
        embedder: (any EmbeddingProvider)?
    ) async throws -> StoredVector? {
        guard let embedder, chunk.embeddable else { return nil }
        let text = (chunk.heading.isEmpty ? title : chunk.heading) + "\n" + chunk.text
        do {
            let tagged = try await embedder.embedTagged(String(text.prefix(2000)))
            return VectorCodec.encode(tagged.vector).map { StoredVector(space: tagged.space, data: $0) }
        } catch is CancellationError {
            throw CancellationError()
        } catch is EmbeddingTextError {
            // This text has no vector and never will: another language, or no usable content.
            return nil
        }
    }
}
