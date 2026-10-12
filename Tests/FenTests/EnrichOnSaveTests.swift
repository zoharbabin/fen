@testable import FenCore
import Foundation
import Testing

private let saveReply = ["B1:\\n- The price is twelve dollars per seat each month [1]\\n"]

@Suite("Enrich on save follows the workspace approval mode (issues #6, #140)", .serialized)
@MainActor
struct EnrichOnSaveTests {
    private func make(
        _ fixture: InlineAIFixture,
        enabled: Bool = true
    ) throws -> (EnrichOnSave, WriteGate) {
        try fixture.library.updateSettings(id: fixture.workspaceID) { $0.enrichOnSave = enabled }
        let gate = WriteGate(library: fixture.library)
        let runner = EnrichOnSave(
            library: fixture.library, service: fixture.service, gate: gate, debounce: .milliseconds(50)
        )
        return (runner, gate)
    }

    private func onDisk(_ fixture: InlineAIFixture) throws -> String {
        try String(contentsOf: fixture.planURL, encoding: .utf8)
    }

    @Test("the setting is off by default, and an older registry without it still loads")
    func defaultsOff() throws {
        #expect(WorkspaceSettings().enrichOnSave == false)
        let old = try JSONEncoder().encode(WorkspaceSettings())
        var object = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object["enrichOnSave"] = nil
        let decoded = try JSONDecoder().decode(
            WorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.enrichOnSave == false)
        var on = WorkspaceSettings()
        on.enrichOnSave = true
        #expect(try JSONDecoder().decode(WorkspaceSettings.self, from: JSONEncoder().encode(on)).enrichOnSave)
    }

    @Test("with the setting off a save does nothing")
    func settingOff() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .autoApprove)
        defer { fixture.cleanUp() }
        let (runner, gate) = try make(fixture, enabled: false)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(fixture.server.requests.isEmpty)
        #expect(try onDisk(fixture) == inlineAIPlanText)
        #expect(gate.pending(for: fixture.workspaceID).isEmpty)
        #expect(gate.entries(for: fixture.workspaceID).isEmpty)
    }

    @Test("on with Ask queues a diff and leaves the file unchanged")
    func askQueues() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .ask)
        defer { fixture.cleanUp() }
        let (runner, gate) = try make(fixture)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(try onDisk(fixture) == inlineAIPlanText)
        let waiting = gate.pending(for: fixture.workspaceID)
        #expect(waiting.count == 1)
        #expect(waiting.first?.change.operation == "enrich")
        #expect(waiting.first?.tier == .additive)
        #expect(waiting.first?.change.invokedByUser == false)
        #expect(gate.entries(for: fixture.workspaceID).isEmpty)
    }

    @Test("on with Auto-approve adds text only, logs it, and one step undoes it")
    func autoApproveAdds() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .autoApprove)
        defer { fixture.cleanUp() }
        let (runner, gate) = try make(fixture)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        let written = try onDisk(fixture)
        for line in inlineAIPlanText.components(separatedBy: "\n") where !line.isEmpty {
            #expect(written.contains(line))
        }
        #expect(written.contains("twelve dollars per seat"))
        let entry = try #require(gate.entries(for: fixture.workspaceID).first)
        #expect(entry.operation == "enrich")
        #expect(entry.tier == .additive)
        #expect(entry.approvedBy == .auto)
        #expect(gate.pending(for: fixture.workspaceID).isEmpty)
        try gate.undo(entry.id, workspaceID: fixture.workspaceID)
        #expect(try onDisk(fixture) == inlineAIPlanText)
    }

    @Test("with approval Off a save does nothing and sends nothing")
    func approvalOff() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .off)
        defer { fixture.cleanUp() }
        let (runner, gate) = try make(fixture)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(fixture.server.requests.isEmpty)
        #expect(try onDisk(fixture) == inlineAIPlanText)
        #expect(gate.pending(for: fixture.workspaceID).isEmpty)
        #expect(gate.entries(for: fixture.workspaceID).isEmpty)
    }

    @Test("with no provider configured a save does nothing")
    func noProvider() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, provider: .none, approval: .autoApprove)
        defer { fixture.cleanUp() }
        let (runner, gate) = try make(fixture)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(fixture.server.requests.isEmpty)
        #expect(try onDisk(fixture) == inlineAIPlanText)
        #expect(gate.entries(for: fixture.workspaceID).isEmpty)
    }

    @Test("a workspace with AI access None is never read for the model")
    func accessNone() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, access: AIDataAccess.none, approval: .autoApprove)
        defer { fixture.cleanUp() }
        let (runner, _) = try make(fixture)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(fixture.server.requests.isEmpty)
        #expect(try onDisk(fixture) == inlineAIPlanText)
    }

    @Test("a file outside every workspace is left alone")
    func outsideWorkspace() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .autoApprove)
        defer { fixture.cleanUp() }
        let (runner, _) = try make(fixture)
        runner.noteSaved(fixture.outsideURL)
        await runner.idle()
        #expect(fixture.server.requests.isEmpty)
        #expect(try String(contentsOf: fixture.outsideURL, encoding: .utf8) == inlineAIPlanText)
    }

    @Test("a burst of saves runs once")
    func burstRunsOnce() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .ask)
        defer { fixture.cleanUp() }
        let (runner, gate) = try make(fixture)
        for _ in 0 ..< 6 {
            runner.noteSaved(fixture.planURL)
        }
        await runner.idle()
        #expect(fixture.server.requests.count == 1)
        #expect(gate.pending(for: fixture.workspaceID).count == 1)
    }

    @Test("saving the same content again does not queue the same diff twice")
    func sameContentOnce() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .ask)
        defer { fixture.cleanUp() }
        let (runner, gate) = try make(fixture)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(fixture.server.requests.count == 1)
        #expect(gate.pending(for: fixture.workspaceID).count == 1)
    }

    @Test("a write Fen made does not start another run")
    func fenWriteDoesNotLoop() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .autoApprove)
        defer { fixture.cleanUp() }
        let (runner, gate) = try make(fixture)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(fixture.server.requests.count == 1)
        #expect(gate.entries(for: fixture.workspaceID).count == 1)
        // The editor reloads the file Fen wrote and saves it again.
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(fixture.server.requests.count == 1)
        #expect(gate.entries(for: fixture.workspaceID).count == 1)
        // A fresh runner has no memory, so the activity log alone has to recognize Fen's own write.
        let restarted = EnrichOnSave(
            library: fixture.library, service: fixture.service, gate: gate, debounce: .milliseconds(50)
        )
        restarted.noteSaved(fixture.planURL)
        await restarted.idle()
        #expect(fixture.server.requests.count == 1)
        #expect(gate.entries(for: fixture.workspaceID).count == 1)
    }

    @Test("a real edit after a run is enriched again")
    func changedContentRunsAgain() async throws {
        let fixture = try await InlineAIFixture(reply: saveReply, approval: .ask)
        defer { fixture.cleanUp() }
        let (runner, _) = try make(fixture)
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        try (inlineAIPlanText + "\n- Pricing per seat again\n").write(
            to: fixture.planURL, atomically: true, encoding: .utf8
        )
        runner.noteSaved(fixture.planURL)
        await runner.idle()
        #expect(fixture.server.requests.count == 2)
    }
}
