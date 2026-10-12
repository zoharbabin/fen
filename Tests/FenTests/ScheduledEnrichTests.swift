@testable import FenCore
import Foundation
import Testing

private let scheduleReply = ["B1:\\n- The price is twelve dollars per seat each month [1]\\n"]
private let day: TimeInterval = 24 * 60 * 60
private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// A clock the test moves by hand. Nothing here waits in real time.
@MainActor
private final class TestClock {
    var date: Date
    init(_ date: Date) {
        self.date = date
    }
}

/// A workspace with a schedule, a hand-moved clock and the pieces the tests look at.
@MainActor
private struct Harness {
    let fixture: InlineAIFixture
    let runner: EnrichOnSave
    let gate: WriteGate
    let clock: TestClock

    /// With `due`, `plan.md` changed after the saved cursor and a day has passed, so a run is due.
    init(
        approval: ApprovalMode = .ask,
        provider: ProviderChoice = .local,
        access: AIDataAccess = .localProvidersOnly,
        schedule: EnrichSchedule = .daily,
        onSave: Bool = false,
        cap: Int = EnrichOnSave.defaultMaxFilesPerRun,
        due: Bool = true
    ) async throws {
        fixture = try await InlineAIFixture(
            reply: scheduleReply, provider: provider, access: access, approval: approval
        )
        clock = TestClock(start)
        try fixture.library.updateSettings(id: fixture.workspaceID) {
            $0.enrichSchedule = schedule
            $0.enrichOnSave = onSave
        }
        gate = WriteGate(library: fixture.library)
        runner = Harness.makeRunner(fixture, gate, clock, cap: cap)
        if due {
            try fixture.library.registry.setScheduledEnrich(
                id: fixture.workspaceID, ScheduledEnrichState(lastRun: start, cursor: start)
            )
            try await touch("plan.md", start.addingTimeInterval(100))
            clock.date = start.addingTimeInterval(day + 1)
        }
    }

    private static func makeRunner(
        _ fixture: InlineAIFixture, _ gate: WriteGate, _ clock: TestClock, cap: Int
    ) -> EnrichOnSave {
        EnrichOnSave(
            library: fixture.library,
            service: fixture.service,
            gate: gate,
            debounce: .milliseconds(50),
            maxFilesPerRun: cap,
            now: { clock.date }
        )
    }

    /// A runner with no memory, as after a restart.
    func restarted() -> EnrichOnSave {
        Harness.makeRunner(fixture, gate, clock, cap: EnrichOnSave.defaultMaxFilesPerRun)
    }

    var state: ScheduledEnrichState? {
        fixture.library.registry.workspace(id: fixture.workspaceID)?.scheduledEnrich
    }

    var pendingPaths: [String] {
        gate.pending(for: fixture.workspaceID).flatMap(\.change.scope).sorted()
    }

    var requests: Int {
        fixture.server.requests.count
    }

    /// Writes `name` with its own heading, then dates it.
    func addFile(_ name: String, modified: Date) async throws {
        let text = inlineAIPlanText.replacingOccurrences(of: "# Plan", with: "# \(name)")
        try fixture.notes.write(name, text)
        try await touch(name, modified)
    }

    /// Sets the modification time, lists the workspace again, and waits until the listing and the index show it.
    func touch(_ name: String, _ date: Date) async throws {
        let url = fixture.notes.root.appendingPathComponent(name)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        fixture.library.refreshAll()
        let id = fixture.workspaceID
        let library = fixture.library
        let ready = try await pollUntilTrue(timeout: .seconds(30)) {
            guard let found = library.state(for: id).snapshot.files[name]?.modified else { return false }
            return abs(found.timeIntervalSince(date)) < 1 && library.state(for: id).phase == .idle
                && library.indexStatus(for: id).phase == .idle
        }
        try #require(ready)
    }

    /// Checks the schedules and waits for every run to end.
    func run(_ target: EnrichOnSave? = nil) async {
        let active = target ?? runner
        active.runDueSchedules()
        await active.idle()
    }

    func onDisk(_ name: String) throws -> String {
        try String(contentsOf: fixture.notes.root.appendingPathComponent(name), encoding: .utf8)
    }
}

@Suite("Scheduled enrichment follows the workspace approval mode (issue #6)", .serialized)
@MainActor
struct ScheduledEnrichTests {
    @Test("the schedule is off by default, and older saved data without it or its state still loads")
    func defaultsOff() throws {
        #expect(WorkspaceSettings().enrichSchedule == .off)
        #expect(EnrichSchedule.off.interval == nil)
        #expect(EnrichSchedule.daily.interval == day)
        #expect(EnrichSchedule.weekly.interval == 7 * day)
        let old = try JSONEncoder().encode(WorkspaceSettings())
        var object = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object["enrichSchedule"] = nil
        let decoded = try JSONDecoder().decode(
            WorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.enrichSchedule == .off)
        var weekly = WorkspaceSettings()
        weekly.enrichSchedule = .weekly
        let again = try JSONDecoder().decode(WorkspaceSettings.self, from: JSONEncoder().encode(weekly))
        #expect(again.enrichSchedule == .weekly)
        // A workspace entry from an older registry has no scheduled state.
        let workspace = try JSONEncoder().encode(Workspace(name: "Old", path: "/tmp/old"))
        var entry = try #require(JSONSerialization.jsonObject(with: workspace) as? [String: Any])
        entry["scheduledEnrich"] = nil
        let loaded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: entry))
        #expect(loaded.scheduledEnrich == nil)
    }

    @Test("with the schedule off a due check does nothing and keeps no state")
    func scheduleOff() async throws {
        let harness = try await Harness(schedule: .off)
        defer { harness.fixture.cleanUp() }
        await harness.run()
        #expect(harness.requests == 0)
        #expect(harness.pendingPaths.isEmpty)
        #expect(try harness.onDisk("plan.md") == inlineAIPlanText)
        #expect(harness.state == nil)
    }

    @Test("turning a schedule on starts its clock and runs nothing, then the run is due one interval later")
    func dueByTheClock() async throws {
        let harness = try await Harness(due: false)
        defer { harness.fixture.cleanUp() }
        try await harness.touch("plan.md", start.addingTimeInterval(100))
        // The first check only starts the clock. The file changed after that, so the next run takes it.
        await harness.run()
        #expect(harness.requests == 0)
        #expect(harness.state?.lastRun == start)
        harness.clock.date = start.addingTimeInterval(day - 1)
        await harness.run()
        #expect(harness.requests == 0)
        #expect(harness.state?.lastRun == start)
        harness.clock.date = start.addingTimeInterval(day)
        await harness.run()
        #expect(harness.requests == 1)
        #expect(harness.pendingPaths == ["plan.md"])
        #expect(harness.state?.lastRun == harness.clock.date)
        // Weekly waits longer than a day.
        try harness.fixture.library.updateSettings(id: harness.fixture.workspaceID) { $0.enrichSchedule = .weekly }
        harness.clock.date = start.addingTimeInterval(7 * day - 1)
        await harness.run()
        #expect(harness.state?.lastRun == start.addingTimeInterval(day))
    }

    @Test("a run takes only the files changed since the last run")
    func onlyChangedFiles() async throws {
        let harness = try await Harness()
        defer { harness.fixture.cleanUp() }
        try await harness.addFile("old.md", modified: start.addingTimeInterval(-500))
        try await harness.addFile("newer.md", modified: start.addingTimeInterval(500))
        try await harness.touch("pricing.md", start.addingTimeInterval(-900))
        await harness.run()
        #expect(harness.requests == 2)
        #expect(harness.pendingPaths == ["newer.md", "plan.md"])
    }

    @Test("the cap holds, and the rest is carried to the next run")
    func capAndCarryOver() async throws {
        let harness = try await Harness(cap: 2)
        defer { harness.fixture.cleanUp() }
        try await harness.addFile("b.md", modified: start.addingTimeInterval(200))
        try await harness.addFile("c.md", modified: start.addingTimeInterval(300))
        let firstRun = harness.clock.date
        await harness.run()
        #expect(harness.requests == 2)
        #expect(harness.pendingPaths == ["b.md", "plan.md"])
        #expect(harness.state?.lastRun == firstRun)
        #expect(harness.state?.cursor == start.addingTimeInterval(200))
        // Not due again the same day.
        harness.clock.date = firstRun.addingTimeInterval(day - 1)
        await harness.run()
        #expect(harness.requests == 2)
        // The next day takes the third file, and no file twice.
        harness.clock.date = firstRun.addingTimeInterval(day)
        await harness.run()
        #expect(harness.requests == 3)
        #expect(harness.pendingPaths == ["b.md", "c.md", "plan.md"])
        #expect(harness.state?.cursor == harness.clock.date)
    }

    @Test("Ask queues a diff and writes nothing")
    func askQueues() async throws {
        let harness = try await Harness(approval: .ask)
        defer { harness.fixture.cleanUp() }
        await harness.run()
        #expect(try harness.onDisk("plan.md") == inlineAIPlanText)
        let waiting = harness.gate.pending(for: harness.fixture.workspaceID)
        #expect(waiting.count == 1)
        #expect(waiting.first?.change.operation == "enrich")
        #expect(waiting.first?.tier == .additive)
        #expect(waiting.first?.change.invokedByUser == false)
        #expect(harness.gate.entries(for: harness.fixture.workspaceID).isEmpty)
    }

    @Test("Auto-approve adds text only, logs it, and one step undoes it")
    func autoApproveAdds() async throws {
        let harness = try await Harness(approval: .autoApprove)
        defer { harness.fixture.cleanUp() }
        await harness.run()
        let written = try harness.onDisk("plan.md")
        for line in inlineAIPlanText.components(separatedBy: "\n") where !line.isEmpty {
            #expect(written.contains(line))
        }
        #expect(written.contains("twelve dollars per seat"))
        let id = harness.fixture.workspaceID
        let entry = try #require(harness.gate.entries(for: id).first)
        #expect(entry.operation == "enrich")
        #expect(entry.tier == .additive)
        #expect(entry.approvedBy == .auto)
        #expect(harness.gate.pending(for: id).isEmpty)
        try harness.gate.undo(entry.id, workspaceID: id)
        #expect(try harness.onDisk("plan.md") == inlineAIPlanText)
    }

    @Test("with approval Off nothing is sent and the files keep waiting")
    func approvalOff() async throws {
        let harness = try await Harness(approval: .off)
        defer { harness.fixture.cleanUp() }
        await harness.run()
        #expect(harness.requests == 0)
        #expect(try harness.onDisk("plan.md") == inlineAIPlanText)
        #expect(harness.gate.pending(for: harness.fixture.workspaceID).isEmpty)
        #expect(harness.gate.entries(for: harness.fixture.workspaceID).isEmpty)
        #expect(harness.state?.lastRun == start)
    }

    @Test("with no provider configured nothing happens and the files keep waiting")
    func noProvider() async throws {
        let harness = try await Harness(approval: .autoApprove, provider: .none)
        defer { harness.fixture.cleanUp() }
        await harness.run()
        #expect(harness.requests == 0)
        #expect(try harness.onDisk("plan.md") == inlineAIPlanText)
        #expect(harness.gate.entries(for: harness.fixture.workspaceID).isEmpty)
        #expect(harness.state?.lastRun == start)
    }

    @Test("a workspace with AI access None is never read for the model")
    func accessNone() async throws {
        let harness = try await Harness(approval: .autoApprove, access: AIDataAccess.none)
        defer { harness.fixture.cleanUp() }
        await harness.run()
        #expect(harness.requests == 0)
        #expect(try harness.onDisk("plan.md") == inlineAIPlanText)
        #expect(harness.gate.entries(for: harness.fixture.workspaceID).isEmpty)
        #expect(harness.state?.lastRun == start)
    }

    @Test("the last run is saved with the workspace list and survives a restart")
    func lastRunPersisted() async throws {
        let harness = try await Harness()
        defer { harness.fixture.cleanUp() }
        await harness.run()
        let saved = try #require(harness.state)
        #expect(saved.lastRun == harness.clock.date)
        let reopened = WorkspaceRegistry(home: harness.fixture.home.home)
        try reopened.load()
        let loaded = try #require(reopened.workspace(id: harness.fixture.workspaceID))
        let reloaded = try #require(loaded.scheduledEnrich)
        // The file keeps whole seconds.
        #expect(abs(reloaded.lastRun.timeIntervalSince(saved.lastRun)) < 1)
        #expect(loaded.settings.enrichSchedule == .daily)
        // Saving the settings form does not touch it.
        try harness.fixture.library.updateSettings(id: harness.fixture.workspaceID) { $0.enrichSchedule = .weekly }
        #expect(harness.state == saved)
    }
}

@Suite("Scheduled enrichment skips what is already handled (issue #6)", .serialized)
@MainActor
struct ScheduledEnrichSkipTests {
    @Test("a run does not enrich what on-save already handled")
    func skipsOnSaveWork() async throws {
        let harness = try await Harness(onSave: true, due: false)
        defer { harness.fixture.cleanUp() }
        harness.runner.noteSaved(harness.fixture.planURL)
        await harness.runner.idle()
        #expect(harness.requests == 1)
        try harness.fixture.library.registry.setScheduledEnrich(
            id: harness.fixture.workspaceID, ScheduledEnrichState(lastRun: start, cursor: start)
        )
        try await harness.touch("plan.md", start.addingTimeInterval(100))
        harness.clock.date = start.addingTimeInterval(day)
        await harness.run()
        #expect(harness.requests == 1)
        #expect(harness.pendingPaths == ["plan.md"])
        #expect(harness.state?.lastRun == harness.clock.date)
    }

    @Test("a run does not enrich a file Fen wrote, even after a restart")
    func skipsFenWrites() async throws {
        let harness = try await Harness(approval: .autoApprove, onSave: true, due: false)
        defer { harness.fixture.cleanUp() }
        let id = harness.fixture.workspaceID
        harness.runner.noteSaved(harness.fixture.planURL)
        await harness.runner.idle()
        #expect(harness.gate.entries(for: id).count == 1)
        try harness.fixture.library.registry.setScheduledEnrich(
            id: id, ScheduledEnrichState(lastRun: start, cursor: start)
        )
        let written = try harness.onDisk("plan.md")
        try await harness.touch("plan.md", start.addingTimeInterval(100))
        harness.clock.date = start.addingTimeInterval(day)
        // The new runner has no memory. The activity log alone shows the file is Fen's own write.
        await harness.run(harness.restarted())
        #expect(harness.requests == 1)
        #expect(harness.gate.entries(for: id).count == 1)
        #expect(try harness.onDisk("plan.md") == written)
    }

    @Test("a file with a diff already waiting is not queued twice, even after a restart")
    func skipsWaitingDiff() async throws {
        let harness = try await Harness()
        defer { harness.fixture.cleanUp() }
        await harness.run()
        #expect(harness.pendingPaths == ["plan.md"])
        try await harness.touch("plan.md", harness.clock.date.addingTimeInterval(5))
        harness.clock.date = harness.clock.date.addingTimeInterval(day)
        await harness.run(harness.restarted())
        #expect(harness.requests == 1)
        #expect(harness.pendingPaths == ["plan.md"])
    }
}
