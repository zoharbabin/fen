import Foundation
import Observation

public enum ScanPhase: Equatable, Sendable {
    case idle
    case scanning(found: Int)
    case canceled
    case failed(String)
}

public struct WorkspaceState: Equatable, Sendable {
    public var snapshot = WorkspaceSnapshot()
    public var phase = ScanPhase.idle
    /// `true` once a scan has finished at least once.
    public var hasScanned = false
}

/// Everything the UI knows about the granted workspaces (issue #5): the list, each one's files,
/// git state, and scan progress.
///
/// - Starts nothing and writes nothing until you add a workspace.
/// - Lists run off the main actor through `WorkspaceJobScheduler`. Typing is never blocked.
/// - macOS watches each folder and updates the list incrementally. iOS refreshes when the app
///   returns to the foreground.
/// - Each listed workspace is indexed in the background for search (issue #35), through `search`.
@MainActor @Observable
public final class WorkspaceLibrary {
    public static let shared = WorkspaceLibrary()

    public let registry: WorkspaceRegistry
    public let search: WorkspaceSearch
    public private(set) var states: [UUID: WorkspaceState] = [:]
    public private(set) var loadError: String?
    /// The workspace shown in front. Its jobs run first.
    public private(set) var currentWorkspaceID: UUID?

    let scheduler: WorkspaceJobScheduler
    @ObservationIgnored private let watching: Bool
    @ObservationIgnored private let indexing: Bool
    @ObservationIgnored private var sources: [UUID: LocalFolderSource] = [:]
    @ObservationIgnored private var watchers: [UUID: WorkspaceChangeWatcher] = [:]
    @ObservationIgnored private var generation: [UUID: Int] = [:]
    @ObservationIgnored private var pendingChanges: [UUID: Set<String>] = [:]
    @ObservationIgnored private var updating: Set<UUID> = []
    @ObservationIgnored private var powerObserver: (any NSObjectProtocol)?

    public init(
        home: FenHome = .standard,
        scheduler: WorkspaceJobScheduler = WorkspaceJobScheduler(),
        watching: Bool = WorkspaceChangeWatcher.isLive,
        indexing: Bool = true,
        embedder: (any EmbeddingProvider)? = AppleSentenceEmbeddingProvider()
    ) {
        registry = WorkspaceRegistry(home: home)
        search = WorkspaceSearch(home: home, scheduler: scheduler, embedder: embedder)
        self.scheduler = scheduler
        self.watching = watching
        self.indexing = indexing
    }

    public var workspaces: [Workspace] {
        registry.workspaces
    }

    public func state(for id: UUID) -> WorkspaceState {
        states[id] ?? WorkspaceState()
    }

    // MARK: - Lifecycle

    /// Reads the saved list and lists each workspace. With no workspaces this only reads.
    public func start() {
        guard states.isEmpty else { return }
        do {
            try registry.load()
            loadError = nil
        } catch {
            loadError = "Fen couldn't read your workspace list: \(error.localizedDescription)"
            return
        }
        guard !registry.workspaces.isEmpty else { return }
        observeLowPower()
        for workspace in registry.workspaces {
            track(workspace.id)
        }
        if currentWorkspaceID == nil {
            setCurrent(registry.workspaces.first?.id)
        }
    }

    /// Call when the app comes to the foreground. Lists every workspace again.
    public func refreshAll() {
        for workspace in registry.workspaces {
            scan(workspace.id)
        }
    }

    // MARK: - Changing the list

    @discardableResult
    public func add(folder: URL, name: String? = nil) throws -> Workspace {
        let workspace = try registry.add(folder: folder, name: name)
        observeLowPower()
        track(workspace.id)
        if currentWorkspaceID == nil {
            setCurrent(workspace.id)
        }
        return workspace
    }

    /// Removes the grant and Fen's state for it. The folder itself is not touched.
    public func remove(id: UUID) throws {
        search.forget(id: id)
        try registry.remove(id: id)
        watchers.removeValue(forKey: id)?.stop()
        sources[id] = nil
        states[id] = nil
        pendingChanges[id] = nil
        generation[id, default: 0] += 1
        Task { await scheduler.cancel(workspaceID: id) }
        if currentWorkspaceID == id {
            setCurrent(registry.workspaces.first?.id)
        }
    }

    public func updateSettings(id: UUID, _ change: (inout WorkspaceSettings) -> Void) throws {
        let before = registry.workspace(id: id)?.settings
        try registry.updateSettings(id: id, change)
        guard let before, let after = registry.workspace(id: id)?.settings else { return }
        let changesList = before.includeGlobs != after.includeGlobs || before.excludeGlobs != after.excludeGlobs
            || before.maxFileBytes != after.maxFileBytes
        if changesList {
            sources[id] = nil
            scan(id)
        }
    }

    /// Deletes every workspace's search index and builds them again. Settings, history and the
    /// workspace list stay. Returns how many indexes were deleted.
    @discardableResult
    public func clearCaches() throws -> Int {
        search.closeAll()
        let removed = try registry.clearCaches()
        for workspace in registry.workspaces {
            requestIndex(workspace.id)
        }
        return removed
    }

    public func setCurrent(_ id: UUID?) {
        currentWorkspaceID = id
        Task { await scheduler.setFrontmost(id) }
    }

    // MARK: - Files

    /// The file's location, checked by the path gate. `nil` if the workspace or path is unknown
    /// or the file isn't eligible.
    public func fileURL(workspaceID: UUID, relativePath: String) -> URL? {
        guard let source = source(for: workspaceID), source.exclusionReason(forRelativePath: relativePath) == nil else {
            return nil
        }
        return source.fileURL(forRelativePath: relativePath)
    }

    // MARK: - Search

    public func indexStatus(for id: UUID) -> IndexStatus {
        search.status(for: id)
    }

    /// Stops indexing a workspace. What was indexed stays, and `resumeIndexing` carries on.
    public func cancelIndexing(id: UUID) {
        search.cancelIndexing(id: id)
    }

    public func resumeIndexing(id: UUID) {
        requestIndex(id)
    }

    /// Searches indexed workspaces without opening their files. See `WorkspaceSearch.search`.
    public func search(
        _ query: String,
        scope: WorkspaceScope,
        destination: ModelDestination? = nil,
        origin: SearchOrigin? = nil,
        limit: Int = 30
    ) async -> [SearchResult] {
        await search.search(
            query,
            in: registry.workspaces,
            scope: scope,
            destination: destination,
            origin: origin,
            limit: limit
        )
    }

    private func requestIndex(_ id: UUID, recheck: Set<String> = []) {
        guard indexing, let source = source(for: id), state(for: id).hasScanned else { return }
        search.reindex(id: id, source: source, files: state(for: id).snapshot.documents, recheck: recheck)
    }

    /// Why a file isn't listed, or `nil` if it is.
    public func exclusionReason(workspaceID: UUID, relativePath: String) -> ExclusionReason? {
        source(for: workspaceID)?.exclusionReason(forRelativePath: relativePath)
    }

    // MARK: - Scanning

    public func cancelScan(id: UUID) {
        generation[id, default: 0] += 1
        if case .scanning = state(for: id).phase {
            states[id]?.phase = .canceled
        }
        Task { await scheduler.cancel(workspaceID: id) }
    }

    /// Lists the workspace from scratch.
    public func scan(_ id: UUID) {
        guard let source = source(for: id) else {
            states[id, default: WorkspaceState()].phase = .failed(failureMessage(for: id))
            return
        }
        generation[id, default: 0] += 1
        let mine = generation[id, default: 0]
        pendingChanges[id] = nil
        states[id, default: WorkspaceState()].phase = .scanning(found: 0)
        Task {
            await scheduler.cancel(workspaceID: id)
            guard mine == generation[id] else { return }
            await scheduler.submit(
                workspaceID: id,
                kind: .listing,
                onProgress: { found, _ in
                    Task { @MainActor in self.scanProgress(id, mine, found) }
                },
                onFinish: { outcome in
                    Task { @MainActor in self.scanFinished(id, mine, outcome) }
                },
                work: { context in
                    let snapshot = try await source.scan { found in context.report(completed: found, total: nil) }
                    try await context.checkpoint()
                    await self.scanSucceeded(id, mine, snapshot)
                }
            )
        }
    }

    private func scanProgress(_ id: UUID, _ mine: Int, _ found: Int) {
        guard mine == generation[id], case .scanning = state(for: id).phase else { return }
        states[id]?.phase = .scanning(found: found)
    }

    private func scanSucceeded(_ id: UUID, _ mine: Int, _ snapshot: WorkspaceSnapshot) {
        guard mine == generation[id], states[id] != nil else { return }
        states[id] = WorkspaceState(snapshot: snapshot, phase: .idle, hasScanned: true)
        requestIndex(id)
        // Changes that arrived during the scan may not be in it.
        if let paths = pendingChanges[id], !paths.isEmpty {
            applyChanges(id)
        }
    }

    private func scanFinished(_ id: UUID, _ mine: Int, _ outcome: JobOutcome) {
        guard mine == generation[id], states[id] != nil else { return }
        switch outcome {
        case .completed: break
        case .canceled: states[id]?.phase = .canceled
        case let .failed(error): states[id]?.phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Incremental updates

    func changesArrived(_ id: UUID, paths: [String]) {
        guard states[id] != nil else { return }
        // A new HEAD means a checkout or pull: many files may have changed at once.
        if paths.contains("") || paths.contains(".git/HEAD") {
            scan(id)
            return
        }
        pendingChanges[id, default: []].formUnion(paths)
        if case .scanning = state(for: id).phase {
            return
        }
        applyChanges(id)
    }

    private func applyChanges(_ id: UUID) {
        guard !updating.contains(id), let source = source(for: id), let paths = pendingChanges[id],
              !paths.isEmpty else {
            return
        }
        pendingChanges[id] = nil
        updating.insert(id)
        let snapshot = state(for: id).snapshot
        let mine = generation[id, default: 0]
        Task {
            await scheduler.submit(
                workspaceID: id,
                kind: .listing,
                onFinish: { _ in Task { @MainActor in self.updateFinished(id) } },
                work: { _ in
                    let updated = try await source.update(snapshot, changedPaths: Array(paths))
                    await self.updateSucceeded(id, mine, updated, changed: paths)
                }
            )
        }
    }

    private func updateSucceeded(_ id: UUID, _ mine: Int, _ snapshot: WorkspaceSnapshot, changed: Set<String>) {
        guard mine == generation[id], states[id] != nil else { return }
        states[id]?.snapshot = snapshot
        requestIndex(id, recheck: changed)
    }

    private func updateFinished(_ id: UUID) {
        updating.remove(id)
        if pendingChanges[id]?.isEmpty == false {
            applyChanges(id)
        }
    }

    // MARK: - Private

    private func track(_ id: UUID) {
        states[id] = WorkspaceState()
        scan(id)
        guard watching, let root = try? registry.rootURL(for: id) else { return }
        let watcher = WorkspaceChangeWatcher(root: root) { paths in
            Task { @MainActor in self.changesArrived(id, paths: paths) }
        }
        watcher.start()
        watchers[id] = watcher
    }

    private func source(for id: UUID) -> LocalFolderSource? {
        if let cached = sources[id] {
            return cached
        }
        guard let workspace = registry.workspace(id: id), let root = try? registry.rootURL(for: id) else { return nil }
        let source = LocalFolderSource(root: root, settings: workspace.settings)
        sources[id] = source
        return source
    }

    private func failureMessage(for id: UUID) -> String {
        guard let name = registry.workspace(id: id)?.name
        else { return WorkspaceError.unknownWorkspace.localizedDescription }
        return WorkspaceError.accessLost(name: name).localizedDescription
    }

    private func observeLowPower() {
        guard powerObserver == nil else { return }
        let scheduler = scheduler
        let apply: @Sendable () -> Void = {
            let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { await scheduler.setLowPowerMode(enabled) }
        }
        apply()
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { _ in apply() }
    }
}
