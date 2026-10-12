import Foundation

/// Enriches a document's short bullets after you save it, when the workspace turned that on (issue #6).
///
/// It is the file-level Enrich (`FileEnricher`) with a trigger. Nothing here decides what may be
/// written: the workspace's approval mode does, through `WriteGate`. Ask queues a diff, Auto-approve
/// adds the facts and logs them, Off does nothing.
///
/// - A burst of saves to one file waits for `debounce` after the last one, then runs once.
/// - The run is a background job under the same concurrency cap as indexing. Typing never waits on it.
/// - A file Fen wrote itself, or already looked at in this state, is not enriched again.
/// - Nothing happens without a configured provider, or when the workspace's AI data access says no.
@MainActor
final class EnrichOnSave {
    static let shared = EnrichOnSave(library: .shared, service: .shared, gate: .shared)

    private struct Key: Hashable {
        let workspaceID: UUID
        let path: String
    }

    private let library: WorkspaceLibrary
    private let service: AIService
    private let gate: WriteGate
    private let debounce: Duration
    private var timers: [Key: Task<Void, Never>] = [:]
    private var running: [Key: Task<Void, Never>] = [:]
    private var saveArrivedWhileRunning: Set<Key> = []
    /// The content hash each file had when it was last looked at. The same content is never run twice.
    private var seen: [Key: String] = [:]

    init(library: WorkspaceLibrary, service: AIService, gate: WriteGate, debounce: Duration = .seconds(5)) {
        self.library = library
        self.service = service
        self.gate = gate
        self.debounce = debounce
    }

    /// Call after a document at `url` was saved. Cheap when the setting is off or nothing applies.
    func noteSaved(_ url: URL) {
        guard library.workspaces.contains(where: \.settings.enrichOnSave), service.isConfigured,
              let place = library.locate(url), place.workspace.settings.enrichOnSave,
              library.exclusionReason(workspaceID: place.workspace.id, relativePath: place.relativePath) == nil,
              InlineAIAccess.reason(library: library, service: service, fileURL: url, operation: "enrich") == nil
        else { return }
        let key = Key(workspaceID: place.workspace.id, path: place.relativePath)
        timers[key]?.cancel()
        timers[key] = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            timers[key] = nil
            start(key)
        }
    }

    /// Returns when every waiting and running enrichment has finished. For tests.
    func idle() async {
        while let task = timers.values.first ?? running.values.first {
            await task.value
        }
    }

    private func start(_ key: Key) {
        guard running[key] == nil else {
            saveArrivedWhileRunning.insert(key)
            return
        }
        running[key] = Task {
            await submitJob(key)
            running[key] = nil
            if saveArrivedWhileRunning.remove(key) != nil {
                start(key)
            }
        }
    }

    /// Runs the enrichment as a background job and returns when it ends.
    private func submitJob(_ key: Key) async {
        let (ended, finish) = AsyncStream<Void>.makeStream()
        await library.scheduler.submit(
            workspaceID: key.workspaceID,
            kind: .background,
            onFinish: { _ in
                finish.yield()
                finish.finish()
            },
            work: { context in
                try await context.checkpoint()
                await self.enrich(key)
            }
        )
        for await _ in ended {}
    }

    private func enrich(_ key: Key) async {
        guard let workspace = library.registry.workspace(id: key.workspaceID), workspace.settings.enrichOnSave,
              let hash = try? gate.contentHash(workspaceID: key.workspaceID, relativePath: key.path),
              seen[key] != hash, !wroteByFen(key, hash: hash) else { return }
        seen[key] = hash
        let runner = FileEnricher(library: library, service: service, gate: gate)
        // A failed background run is dropped. The next save tries again.
        guard let result = try? await runner.enrich(workspaceID: key.workspaceID, relativePath: key.path)
        else { return }
        if result == .applied {
            // What Fen just wrote is not a save to enrich again.
            seen[key] = try? gate.contentHash(workspaceID: key.workspaceID, relativePath: key.path)
        }
    }

    /// Whether the file is exactly what the last Fen change to it left.
    private func wroteByFen(_ key: Key, hash: String) -> Bool {
        gate.entries(for: key.workspaceID).last { $0.path == key.path && !$0.isUndone }?.postHash == hash
    }
}
