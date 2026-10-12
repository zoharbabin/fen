import Foundation

/// Enriches a document's short bullets after you save it, or on a schedule, when the workspace turned
/// that on (issue #6).
///
/// It is the file-level Enrich (`FileEnricher`) with two triggers. Nothing here decides what may be
/// written: the workspace's approval mode does, through `WriteGate`. Ask queues a diff, Auto-approve
/// adds the facts and logs them, Off does nothing.
///
/// - A burst of saves to one file waits for `debounce` after the last one, then runs once.
/// - A schedule (Daily or Weekly) works only while Fen runs. A due run takes the files whose
///   modification time is newer than the workspace's saved cursor, oldest first, at most `maxFilesPerRun`.
///   Any left over wait for the next run.
/// - Every run is a background job under the same concurrency cap as indexing, and it waits in Low Power
///   Mode. Typing never waits on it.
/// - A file Fen wrote itself, or already looked at in this state, is not enriched again.
/// - Nothing happens without a configured provider, or when the workspace's AI data access says no.
@MainActor
final class EnrichOnSave {
    static let shared = EnrichOnSave(library: .shared, service: .shared, gate: .shared)
    /// The most files one scheduled run looks at.
    static let defaultMaxFilesPerRun = 20

    private struct Key: Hashable {
        let workspaceID: UUID
        let path: String
    }

    private let library: WorkspaceLibrary
    private let service: AIService
    private let gate: WriteGate
    private let debounce: Duration
    private let maxFilesPerRun: Int
    private let now: () -> Date
    private var schedulePoll: Task<Void, Never>?
    private var scheduleRuns: [UUID: Task<Void, Never>] = [:]
    private var timers: [Key: Task<Void, Never>] = [:]
    private var running: [Key: Task<Void, Never>] = [:]
    private var saveArrivedWhileRunning: Set<Key> = []
    /// The content hash each file had when it was last looked at. The same content is never run twice.
    private var seen: [Key: String] = [:]

    init(
        library: WorkspaceLibrary,
        service: AIService,
        gate: WriteGate,
        debounce: Duration = .seconds(5),
        maxFilesPerRun: Int = EnrichOnSave.defaultMaxFilesPerRun,
        now: @escaping () -> Date = { Date() }
    ) {
        self.library = library
        self.service = service
        self.gate = gate
        self.debounce = debounce
        self.maxFilesPerRun = maxFilesPerRun
        self.now = now
    }

    /// Call once at launch. Checks for due schedules now, then every `every`. The workspace list is read
    /// only if it is not loaded yet, and the workspaces are listed only if one has a schedule.
    func launch(every: Duration = .seconds(15 * 60)) {
        guard schedulePoll == nil else { return }
        if library.states.isEmpty {
            try? library.registry.load()
            if library.workspaces.contains(where: { $0.settings.enrichSchedule != .off }) {
                library.start()
            }
        }
        schedulePoll = Task {
            while !Task.isCancelled {
                runDueSchedules()
                try? await Task.sleep(for: every)
            }
        }
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

    /// Starts a run for each workspace whose schedule is due. Cheap when none is. The first call after
    /// you turn a schedule on only starts its clock, so a run never reaches back before that moment.
    func runDueSchedules() {
        let current = now()
        for workspace in library.workspaces {
            let id = workspace.id
            guard let interval = workspace.settings.enrichSchedule.interval else {
                if workspace.scheduledEnrich != nil {
                    try? library.registry.setScheduledEnrich(id: id, nil)
                }
                continue
            }
            guard let state = workspace.scheduledEnrich else {
                try? library.registry.setScheduledEnrich(
                    id: id, ScheduledEnrichState(lastRun: current, cursor: current)
                )
                continue
            }
            guard current >= state.lastRun.addingTimeInterval(interval), scheduleRuns[id] == nil else { continue }
            scheduleRuns[id] = Task {
                await submitJob(id) { await self.runSchedule(id, startedAt: current) }
                scheduleRuns[id] = nil
            }
        }
    }

    /// Returns when every waiting and running enrichment has finished. For tests.
    func idle() async {
        while let task = timers.values.first ?? running.values.first ?? scheduleRuns.values.first {
            await task.value
        }
    }

    private func start(_ key: Key) {
        guard running[key] == nil else {
            saveArrivedWhileRunning.insert(key)
            return
        }
        running[key] = Task {
            await submitJob(key.workspaceID) { await self.enrich(key) }
            running[key] = nil
            if saveArrivedWhileRunning.remove(key) != nil {
                start(key)
            }
        }
    }

    /// Runs `body` as a background job and returns when it ends.
    private func submitJob(_ workspaceID: UUID, _ body: @escaping @MainActor @Sendable () async -> Void) async {
        let (ended, finish) = AsyncStream<Void>.makeStream()
        await library.scheduler.submit(
            workspaceID: workspaceID,
            kind: .background,
            onFinish: { _ in
                finish.yield()
                finish.finish()
            },
            work: { context in
                try await context.checkpoint()
                await body()
            }
        )
        for await _ in ended {}
    }

    /// The body of one scheduled run. A run that cannot start (no provider, access None, approval Off)
    /// leaves the saved state alone, so the files wait for the next chance.
    private func runSchedule(_ id: UUID, startedAt: Date) async {
        guard let workspace = library.registry.workspace(id: id),
              let interval = workspace.settings.enrichSchedule.interval,
              let state = workspace.scheduledEnrich, startedAt >= state.lastRun.addingTimeInterval(interval)
        else { return }
        let changed = library.state(for: id).snapshot.documents
            .filter { Self.seconds($0.modified) > Self.seconds(state.cursor) }
            .sorted { ($0.modified, $0.relativePath) < ($1.modified, $1.relativePath) }
        if let first = changed.first {
            let url = library.fileURL(workspaceID: id, relativePath: first.relativePath)
            guard InlineAIAccess.reason(library: library, service: service, fileURL: url, operation: "enrich") == nil
            else { return }
        }
        let batch = changed.prefix(maxFilesPerRun)
        for file in batch {
            guard !Task.isCancelled else { return }
            let key = Key(workspaceID: id, path: file.relativePath)
            // A diff for this file may already wait, for example from before a restart.
            guard !gate.pending(for: id).contains(where: { $0.change.scope.contains(key.path) }),
                  library.exclusionReason(workspaceID: id, relativePath: key.path) == nil else { continue }
            await enrich(key)
        }
        let cursor = changed.count > batch.count ? (batch.last?.modified ?? startedAt) : startedAt
        try? library.registry.setScheduledEnrich(id: id, ScheduledEnrichState(lastRun: startedAt, cursor: cursor))
    }

    /// File times are compared by the second, the way the saved cursor keeps them.
    private static func seconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    private func enrich(_ key: Key) async {
        guard let workspace = library.registry.workspace(id: key.workspaceID),
              workspace.settings.enrichOnSave || workspace.settings.enrichSchedule != .off,
              let hash = try? gate.contentHash(workspaceID: key.workspaceID, relativePath: key.path),
              seen[key] != hash, !wroteByFen(key, hash: hash) else { return }
        seen[key] = hash
        let runner = FileEnricher(library: library, service: service, gate: gate)
        // A failed background run is dropped. The next save or run tries again.
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

/// The app's one call to start scheduled enrichment at launch (issue #6).
public enum ScheduledEnrichment {
    @MainActor public static func launch() {
        EnrichOnSave.shared.launch()
    }
}
