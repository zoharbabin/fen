import Foundation

public enum JobKind: Sendable {
    /// Listing a workspace's files. Short and visible, so it runs even when background work is
    /// paused.
    case listing
    /// Indexing, classifying, surfacing. Waits while paused or in Low Power Mode.
    case background
}

public enum JobOutcome: Sendable {
    case completed
    case canceled
    case failed(any Error)
}

/// Handed to a running job. Call `checkpoint()` every few dozen items so the job stops promptly
/// when canceled, and waits while background work is paused.
public final class JobContext: Sendable {
    private let scheduler: WorkspaceJobScheduler
    private let kind: JobKind
    private let sink: @Sendable (Int, Int?) -> Void

    init(scheduler: WorkspaceJobScheduler, kind: JobKind, sink: @escaping @Sendable (Int, Int?) -> Void) {
        self.scheduler = scheduler
        self.kind = kind
        self.sink = sink
    }

    public func report(completed: Int, total: Int?) {
        sink(completed, total)
    }

    /// Throws `CancellationError` once canceled. Suspends while paused.
    public func checkpoint() async throws {
        try await scheduler.waitUntilAllowed(kind)
    }
}

/// Runs background work for all workspaces under one concurrency cap (issue #5).
///
/// - The frontmost workspace's jobs go first. Others run in the order submitted.
/// - Jobs run at utility priority, off the main actor, so typing is never starved.
/// - Background jobs wait while you pause them or the device is in Low Power Mode. Listing jobs
///   have their own small lane, so the sidebar still fills in.
public actor WorkspaceJobScheduler {
    public static var defaultConcurrency: Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    private struct Job {
        let id: UUID
        let workspaceID: UUID
        let kind: JobKind
        let order: Int
        let work: @Sendable (JobContext) async throws -> Void
        let onProgress: @Sendable (Int, Int?) -> Void
        let onFinish: @Sendable (JobOutcome) -> Void
    }

    private let maxConcurrent: Int
    private let maxListing = 2
    private var pending: [Job] = []
    private var running: [UUID: (job: Job, task: Task<Void, Never>)] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var frontmost: UUID?
    private var isPaused = false
    private var isLowPower: Bool
    private var counter = 0

    public init(maxConcurrent: Int = WorkspaceJobScheduler.defaultConcurrency, lowPowerMode: Bool = false) {
        self.maxConcurrent = max(1, maxConcurrent)
        isLowPower = lowPowerMode
    }

    // MARK: - Submitting

    @discardableResult
    public func submit(
        workspaceID: UUID,
        kind: JobKind,
        onProgress: @escaping @Sendable (Int, Int?) -> Void = { _, _ in },
        onFinish: @escaping @Sendable (JobOutcome) -> Void = { _ in },
        work: @escaping @Sendable (JobContext) async throws -> Void
    ) -> UUID {
        counter += 1
        let job = Job(
            id: UUID(),
            workspaceID: workspaceID,
            kind: kind,
            order: counter,
            work: work,
            onProgress: onProgress,
            onFinish: onFinish
        )
        pending.append(job)
        startEligible()
        return job.id
    }

    // MARK: - Control

    public func setFrontmost(_ workspaceID: UUID?) {
        frontmost = workspaceID
    }

    /// Pauses or resumes background jobs. Running ones stop at their next checkpoint.
    public func setPaused(_ paused: Bool) {
        isPaused = paused
        backgroundGateChanged()
    }

    public func setLowPowerMode(_ enabled: Bool) {
        isLowPower = enabled
        backgroundGateChanged()
    }

    /// Cancels every pending and running job of one workspace.
    public func cancel(workspaceID: UUID) {
        let dropped = pending.filter { $0.workspaceID == workspaceID }
        pending.removeAll { $0.workspaceID == workspaceID }
        dropped.forEach { $0.onFinish(.canceled) }
        for entry in running.values where entry.job.workspaceID == workspaceID {
            entry.task.cancel()
        }
        wakeWaiters()
    }

    /// Cancels one job, pending or running.
    public func cancel(jobID: UUID) {
        if let dropped = pending.first(where: { $0.id == jobID }) {
            pending.removeAll { $0.id == jobID }
            dropped.onFinish(.canceled)
        }
        running[jobID]?.task.cancel()
        wakeWaiters()
    }

    public func cancelAll() {
        let dropped = pending
        pending.removeAll()
        dropped.forEach { $0.onFinish(.canceled) }
        for entry in running.values {
            entry.task.cancel()
        }
        wakeWaiters()
    }

    // MARK: - State, for tests and progress UI

    public var runningCount: Int {
        running.count
    }

    public var pendingCount: Int {
        pending.count
    }

    /// Jobs waiting at a checkpoint for background work to be allowed.
    public var parkedCount: Int {
        waiters.count
    }

    public var backgroundIsAllowed: Bool {
        !isPaused && !isLowPower
    }

    // MARK: - Running

    private func startEligible() {
        while let next = nextJob() {
            pending.removeAll { $0.id == next.id }
            start(next)
        }
    }

    private func nextJob() -> Job? {
        let listingRunning = running.values.filter(\.job.kind.isListing).count
        let backgroundRunning = running.count - listingRunning
        let candidates = pending.filter { job in
            job.kind.isListing ? listingRunning < maxListing : backgroundRunning < maxConcurrent
        }
        // Order: listing before background, frontmost workspace first, then first come first served.
        return candidates.min { lhs, rhs in
            let left = (lhs.kind.isListing ? 0 : 1, lhs.workspaceID == frontmost ? 0 : 1, lhs.order)
            let right = (rhs.kind.isListing ? 0 : 1, rhs.workspaceID == frontmost ? 0 : 1, rhs.order)
            return left < right
        }
    }

    private func start(_ job: Job) {
        let context = JobContext(scheduler: self, kind: job.kind, sink: job.onProgress)
        let task = Task(priority: .utility) { [weak self] in
            var outcome = JobOutcome.completed
            do {
                try await job.work(context)
                if Task.isCancelled {
                    outcome = .canceled
                }
            } catch is CancellationError {
                outcome = .canceled
            } catch {
                outcome = .failed(error)
            }
            await self?.finish(job.id, outcome)
        }
        running[job.id] = (job, task)
    }

    private func finish(_ id: UUID, _ outcome: JobOutcome) {
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.job.onFinish(outcome)
        startEligible()
    }

    // MARK: - Pausing

    fileprivate func waitUntilAllowed(_ kind: JobKind) async throws {
        try Task.checkCancellation()
        guard !kind.isListing else { return }
        while !backgroundIsAllowed {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                    }
                }
            } onCancel: {
                Task { await self.wakeWaiters() }
            }
            try Task.checkCancellation()
        }
    }

    private func backgroundGateChanged() {
        if backgroundIsAllowed {
            wakeWaiters()
        }
        startEligible()
    }

    private func wakeWaiters() {
        let parked = waiters
        waiters.removeAll()
        parked.forEach { $0.resume() }
    }
}

private extension JobKind {
    var isListing: Bool {
        if case .listing = self {
            true
        } else {
            false
        }
    }
}
