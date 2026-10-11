@testable import FenCore
import Foundation
import Testing

private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor Log {
    private(set) var items: [String] = []
    private var active = 0
    private(set) var peak = 0

    func add(_ item: String) {
        items.append(item)
    }

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
    }
}

private func label(_ outcome: JobOutcome) -> String {
    switch outcome {
    case .completed: "completed"
    case .canceled: "canceled"
    case .failed: "failed"
    }
}

private struct Boom: Error {}

@Suite("WorkspaceJobScheduler")
struct WorkspaceJobSchedulerTests {
    @Test("never runs more background jobs than the cap")
    func capIsRespected() async throws {
        let scheduler = WorkspaceJobScheduler(maxConcurrent: 2)
        let latch = Latch()
        let log = Log()
        for _ in 0 ..< 6 {
            await scheduler.submit(
                workspaceID: UUID(),
                kind: .background,
                onFinish: { outcome in Task { await log.add(label(outcome)) } },
                work: { _ in
                    await log.enter()
                    await latch.wait()
                    await log.leave()
                }
            )
        }
        #expect(try await pollUntilTrue { await scheduler.runningCount == 2 })
        #expect(await scheduler.pendingCount == 4)
        await latch.open()
        #expect(try await pollUntilTrue { await log.items.count == 6 })
        #expect(await log.peak <= 2)
        #expect(await log.items.allSatisfy { $0 == "completed" })
    }

    @Test("the frontmost workspace's jobs start first")
    func frontmostFirst() async throws {
        let scheduler = WorkspaceJobScheduler(maxConcurrent: 1)
        let latch = Latch()
        let log = Log()
        let blocker = UUID()
        let others = (0 ..< 3).map { _ in UUID() }
        await scheduler.submit(workspaceID: blocker, kind: .background) { _ in await latch.wait() }
        #expect(try await pollUntilTrue { await scheduler.runningCount == 1 })
        for (index, id) in others.enumerated() {
            await scheduler.submit(workspaceID: id, kind: .background) { _ in await log.add("w\(index)") }
        }
        await scheduler.setFrontmost(others[2])
        await latch.open()
        #expect(try await pollUntilTrue { await log.items.count == 3 })
        #expect(await log.items == ["w2", "w0", "w1"])
    }

    @Test("canceling a workspace stops its running and pending jobs, and no others")
    func cancelByWorkspace() async throws {
        let scheduler = WorkspaceJobScheduler(maxConcurrent: 1)
        let log = Log()
        let doomed = UUID()
        let survivor = UUID()
        await scheduler.submit(
            workspaceID: doomed,
            kind: .background,
            onFinish: { outcome in Task { await log.add("doomed-running:" + label(outcome)) } },
            work: { context in
                while true {
                    try await context.checkpoint()
                    await Task.yield()
                }
            }
        )
        #expect(try await pollUntilTrue { await scheduler.runningCount == 1 })
        await scheduler.submit(
            workspaceID: doomed,
            kind: .background,
            onFinish: { outcome in Task { await log.add("doomed-pending:" + label(outcome)) } },
            work: { _ in }
        )
        await scheduler.submit(
            workspaceID: survivor,
            kind: .background,
            onFinish: { outcome in Task { await log.add("survivor:" + label(outcome)) } },
            work: { _ in }
        )
        await scheduler.cancel(workspaceID: doomed)
        #expect(try await pollUntilTrue { await log.items.count == 3 })
        #expect(await Set(log.items) == [
            "doomed-running:canceled", "doomed-pending:canceled", "survivor:completed",
        ])
    }

    @Test("a paused background job waits at its checkpoint and resumes")
    func pauseAndResume() async throws {
        let scheduler = WorkspaceJobScheduler(maxConcurrent: 2)
        let log = Log()
        await scheduler.setPaused(true)
        await scheduler.submit(
            workspaceID: UUID(),
            kind: .background,
            onFinish: { outcome in Task { await log.add(label(outcome)) } },
            work: { context in
                try await context.checkpoint()
                await log.add("worked")
            }
        )
        #expect(try await pollUntilTrue { await scheduler.parkedCount == 1 })
        #expect(await log.items.isEmpty)
        await scheduler.setPaused(false)
        #expect(try await pollUntilTrue { await log.items.count == 2 })
        #expect(await log.items == ["worked", "completed"])
    }

    @Test("Low Power Mode holds background jobs and lets listing jobs run")
    func lowPowerBackoff() async throws {
        let scheduler = WorkspaceJobScheduler(maxConcurrent: 2, lowPowerMode: true)
        let log = Log()
        await scheduler.submit(workspaceID: UUID(), kind: .background) { context in
            try await context.checkpoint()
            await log.add("background")
        }
        await scheduler.submit(workspaceID: UUID(), kind: .listing) { context in
            try await context.checkpoint()
            await log.add("listing")
        }
        #expect(try await pollUntilTrue { await scheduler.parkedCount == 1 })
        #expect(try await pollUntilTrue { await log.items == ["listing"] })
        await scheduler.setLowPowerMode(false)
        #expect(try await pollUntilTrue { await log.items.count == 2 })
        #expect(await log.items == ["listing", "background"])
    }

    @Test("canceling a parked job wakes it")
    func cancelWhileParked() async throws {
        let scheduler = WorkspaceJobScheduler(maxConcurrent: 1)
        let log = Log()
        let id = UUID()
        await scheduler.setPaused(true)
        await scheduler.submit(
            workspaceID: id,
            kind: .background,
            onFinish: { outcome in Task { await log.add(label(outcome)) } },
            work: { context in
                try await context.checkpoint()
                await log.add("worked")
            }
        )
        #expect(try await pollUntilTrue { await scheduler.parkedCount == 1 })
        await scheduler.cancel(workspaceID: id)
        #expect(try await pollUntilTrue { await log.items == ["canceled"] })
        #expect(await scheduler.parkedCount == 0)
        #expect(await scheduler.runningCount == 0)
    }

    @Test("a listing job runs while every background slot is busy")
    func listingHasItsOwnLane() async throws {
        let scheduler = WorkspaceJobScheduler(maxConcurrent: 1)
        let latch = Latch()
        let log = Log()
        await scheduler.submit(workspaceID: UUID(), kind: .background) { _ in await latch.wait() }
        #expect(try await pollUntilTrue { await scheduler.runningCount == 1 })
        await scheduler.submit(workspaceID: UUID(), kind: .listing) { _ in await log.add("listed") }
        #expect(try await pollUntilTrue { await log.items == ["listed"] })
        await latch.open()
    }

    @Test("progress and failures reach the caller")
    func progressAndFailure() async throws {
        let scheduler = WorkspaceJobScheduler(maxConcurrent: 1)
        let log = Log()
        await scheduler.submit(
            workspaceID: UUID(),
            kind: .background,
            onProgress: { done, total in Task { await log.add("\(done)/\(total ?? -1)") } },
            onFinish: { outcome in Task { await log.add(label(outcome)) } },
            work: { context in
                context.report(completed: 1, total: 2)
                context.report(completed: 2, total: 2)
            }
        )
        await scheduler.submit(
            workspaceID: UUID(),
            kind: .background,
            onFinish: { outcome in Task { await log.add("second:" + label(outcome)) } },
            work: { _ in throw Boom() }
        )
        #expect(try await pollUntilTrue { await log.items.count == 4 })
        #expect(await Set(log.items) == ["1/2", "2/2", "completed", "second:failed"])
    }
}
