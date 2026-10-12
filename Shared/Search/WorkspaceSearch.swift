import Foundation
import Observation

/// What a workspace's search index is doing and holds.
public struct IndexStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case indexing(done: Int, total: Int)
        case canceled
        case failed(String)
    }

    public var phase = Phase.idle
    public var documents = 0
    public var chunks = 0
    public var embeddedChunks = 0
    /// `true` once the index holds vectors, so searches can match meaning and not only words.
    public var isSemantic: Bool {
        embeddedChunks > 0
    }
}

/// Builds and queries the per-workspace search indexes (issue #35). Owned by `WorkspaceLibrary`.
///
/// - Indexing runs as a background job under the shared concurrency cap. It waits in Low Power
///   Mode and while background work is paused. Typing never waits on it.
/// - Nothing is created on disk for a workspace until its first index run.
/// - Searching never reads a workspace file. It only queries the indexes.
@MainActor @Observable
public final class WorkspaceSearch {
    public private(set) var statuses: [UUID: IndexStatus] = [:]
    /// Bumps whenever an index changes, so a visible result list can ask again.
    public private(set) var revision = 0

    @ObservationIgnored private let home: FenHome
    @ObservationIgnored private let scheduler: WorkspaceJobScheduler
    @ObservationIgnored private let embedder: (any EmbeddingProvider)?
    @ObservationIgnored private var identityTask: Task<EmbedderIdentity?, Never>?
    @ObservationIgnored private(set) var indexes: [UUID: SearchIndex] = [:]
    @ObservationIgnored private var epoch: [UUID: Int] = [:]
    @ObservationIgnored private var running: Set<UUID> = []
    @ObservationIgnored private var jobs: [UUID: UUID] = [:]
    @ObservationIgnored private var latest: [UUID: (source: any WorkspaceSource, files: [WorkspaceFile])] = [:]
    @ObservationIgnored private var recheck: [UUID: Set<String>] = [:]

    public init(home: FenHome, scheduler: WorkspaceJobScheduler, embedder: (any EmbeddingProvider)?) {
        self.home = home
        self.scheduler = scheduler
        self.embedder = embedder
    }

    public func status(for id: UUID) -> IndexStatus {
        statuses[id] ?? IndexStatus()
    }

    // MARK: - Indexing

    /// Asks for the index to match `files`. If a run is going, it runs once more when it ends.
    func reindex(id: UUID, source: any WorkspaceSource, files: [WorkspaceFile], recheck changed: Set<String> = []) {
        latest[id] = (source, files)
        recheck[id, default: []].formUnion(changed)
        if !running.contains(id) {
            start(id)
        }
    }

    /// Stops the run for one workspace. What it indexed so far stays. `reindex` resumes it.
    func cancelIndexing(id: UUID) {
        latest[id] = nil
        guard let job = jobs[id] else { return }
        Task { await scheduler.cancel(jobID: job) }
    }

    /// Drops everything held for a workspace that was removed.
    func forget(id: UUID) {
        epoch[id, default: 0] += 1
        latest[id] = nil
        recheck[id] = nil
        running.remove(id)
        jobs[id] = nil
        statuses[id] = nil
        if let index = indexes.removeValue(forKey: id) {
            index.markClosed()
            Task { await index.close() }
        }
        revision += 1
    }

    /// Closes every index so the folders can be deleted. The library then asks for new runs.
    func closeAll() {
        for id in Array(indexes.keys) + Array(statuses.keys) {
            forget(id: id)
        }
    }

    private func start(_ id: UUID) {
        guard let request = latest.removeValue(forKey: id) else { return }
        running.insert(id)
        let mine = epoch[id, default: 0]
        let changed = recheck.removeValue(forKey: id) ?? []
        statuses[id, default: IndexStatus()].phase = .indexing(done: 0, total: 0)
        Task {
            let identity = await resolveIdentity()
            let index = existingOrNewIndex(id, identity: identity)
            guard mine == epoch[id, default: 0] else { return }
            let usable = identity == nil ? nil : embedder
            let job = await scheduler.submit(
                workspaceID: id,
                kind: .background,
                onProgress: { done, total in
                    Task { @MainActor in self.progress(id, mine, done, total ?? 0) }
                },
                onFinish: { outcome in
                    Task { @MainActor in await self.finished(id, mine, index, outcome) }
                },
                work: { context in
                    _ = try await WorkspaceIndexer.run(
                        index: index,
                        source: request.source,
                        files: request.files,
                        embedder: usable,
                        recheck: changed,
                        context: context
                    )
                }
            )
            if mine == epoch[id, default: 0], running.contains(id) {
                jobs[id] = job
            }
        }
    }

    private func progress(_ id: UUID, _ mine: Int, _ done: Int, _ total: Int) {
        guard mine == epoch[id, default: 0], running.contains(id) else { return }
        statuses[id, default: IndexStatus()].phase = .indexing(done: done, total: total)
    }

    private func finished(_ id: UUID, _ mine: Int, _ index: SearchIndex, _ outcome: JobOutcome) async {
        guard mine == epoch[id, default: 0] else { return }
        running.remove(id)
        jobs[id] = nil
        var status = statuses[id] ?? IndexStatus()
        switch outcome {
        case .completed: status.phase = .idle
        case .canceled: status.phase = .canceled
        case let .failed(error): status.phase = .failed(error.localizedDescription)
        }
        if let summary = try? await index.summary(), mine == epoch[id, default: 0] {
            status.documents = summary.documents
            status.chunks = summary.chunks
            status.embeddedChunks = summary.embeddedChunks
        }
        statuses[id] = status
        revision += 1
        if latest[id] != nil {
            start(id)
        }
    }

    private func resolveIdentity() async -> EmbedderIdentity? {
        if let identityTask {
            return await identityTask.value
        }
        let embedder = embedder
        let task = Task.detached(priority: .utility) { () -> EmbedderIdentity? in
            guard let embedder, embedder.runsOnDevice, embedder.isAvailable else { return nil }
            return EmbedderIdentity(id: embedder.id, dimension: embedder.dimension)
        }
        identityTask = task
        return await task.value
    }

    private func existingOrNewIndex(_ id: UUID, identity: EmbedderIdentity?) -> SearchIndex {
        if let existing = indexes[id] {
            return existing
        }
        let index = SearchIndex(directory: home.indexDirectory(id: id), embedder: identity)
        indexes[id] = index
        return index
    }

    // MARK: - Searching

    /// Searches the indexes of the workspaces in `scope`.
    ///
    /// - Parameters:
    ///   - destination: where the results go. With `.model`, workspaces whose AI data access does
    ///     not allow that destination are left out, even for `.all`.
    ///   - origin: the file you are in. Files near it rank a little higher.
    ///   - meaning: the text to embed, when it should differ from the words to match. A long
    ///     selection matches by a few key words and by its whole meaning.
    ///   - anyWord: match a result that has any of the words, not all of them. For key words
    ///     taken from a longer text.
    public func search(
        _ query: String,
        meaning: String? = nil,
        anyWord: Bool = false,
        in workspaces: [Workspace],
        scope: WorkspaceScope,
        destination: SearchDestination,
        origin: SearchOrigin? = nil,
        limit: Int = 30
    ) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let targets = WorkspaceAccessPolicy.eligible(
            workspaces,
            scope: scope,
            destination: destination.modelDestination
        )
        .compactMap { workspace in indexes[workspace.id].map { (workspace, $0) } }
        guard !targets.isEmpty else { return [] }

        let queryVector = await vector(forQuery: meaning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed)
        let perWorkspace = 50
        let candidates = await withTaskGroup(of: WorkspaceCandidates.self) { group in
            for (workspace, index) in targets {
                group.addTask {
                    let text = await (try? index.textCandidates(
                        matching: trimmed,
                        anyWord: anyWord,
                        limit: perWorkspace
                    )) ?? []
                    var meaning: [VectorCandidate] = []
                    if let queryVector {
                        meaning = await (try? index.vectorCandidates(for: queryVector, limit: perWorkspace)) ?? []
                    }
                    return WorkspaceCandidates(
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        text: text,
                        vector: meaning
                    )
                }
            }
            var all: [WorkspaceCandidates] = []
            for await item in group {
                all.append(item)
            }
            return all
        }
        return HybridRanker.rank(
            candidates,
            similarityFloor: embedder?.similarityFloor ?? 0,
            origin: origin,
            limit: limit
        )
    }

    /// The cosine below which a match is noise for the on-device model. 0 when there is none.
    public var similarityFloor: Float {
        embedder?.similarityFloor ?? 0
    }

    /// The unit-length vector of `text` from the on-device model, or `nil` when there is none (no
    /// model, a language it doesn't cover). Nothing leaves the device.
    public func embedding(of text: String) async -> [Float]? {
        await vector(forQuery: text)
    }

    private func vector(forQuery query: String) async -> [Float]? {
        guard let embedder, await resolveIdentity() != nil,
              let raw = try? await embedder.embed(query) else { return nil }
        return VectorCodec.normalized(raw)
    }
}
