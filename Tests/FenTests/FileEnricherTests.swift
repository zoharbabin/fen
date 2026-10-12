@testable import FenCore
import Foundation
import Testing

private let enrichReply = ["B1:\\n- The price is twelve dollars per seat each month [1]\\n"]

@Suite("Enrich a whole file under the write rules (issues #6, #140)", .serialized)
@MainActor
struct FileEnricherTests {
    private func enricher(_ fixture: InlineAIFixture) -> (FileEnricher, WriteGate) {
        let gate = WriteGate(library: fixture.library)
        return (FileEnricher(library: fixture.library, service: fixture.service, gate: gate), gate)
    }

    private func onDisk(_ fixture: InlineAIFixture) throws -> String {
        try String(contentsOf: fixture.planURL, encoding: .utf8)
    }

    @Test("Ask queues a diff and never writes")
    func askQueues() async throws {
        let fixture = try await InlineAIFixture(reply: enrichReply, approval: .ask)
        defer { fixture.cleanUp() }
        let (runner, gate) = enricher(fixture)
        let result = try await runner.enrich(workspaceID: fixture.workspaceID, relativePath: "plan.md")
        #expect(result == .queued)
        #expect(try onDisk(fixture) == inlineAIPlanText)
        let waiting = gate.pending(for: fixture.workspaceID)
        #expect(waiting.count == 1)
        #expect(waiting.first?.tier == .additive)
        #expect(waiting.first?.change.operation == "enrich")
        #expect(waiting.first?.change.provenance.sources == ["pricing.md"])
        #expect(gate.activity[fixture.workspaceID]?.isEmpty ?? true)
    }

    @Test("approving the queued diff adds the fact and keeps every original line")
    func approvingWrites() async throws {
        let fixture = try await InlineAIFixture(reply: enrichReply, approval: .ask)
        defer { fixture.cleanUp() }
        let (runner, gate) = enricher(fixture)
        _ = try await runner.enrich(workspaceID: fixture.workspaceID, relativePath: "plan.md")
        let item = try #require(gate.pending(for: fixture.workspaceID).first)
        try gate.approve(item.id)
        let written = try onDisk(fixture)
        for line in inlineAIPlanText.components(separatedBy: "\n") where !line.isEmpty {
            #expect(written.contains(line))
        }
        #expect(written
            .contains("    - The price is twelve dollars per seat each month ([Decision](pricing.md#decision))"))
    }

    @Test("Auto-approve adds the facts, logs them, and one step undoes them")
    func autoApproveApplies() async throws {
        let fixture = try await InlineAIFixture(reply: enrichReply, approval: .autoApprove)
        defer { fixture.cleanUp() }
        let (runner, gate) = enricher(fixture)
        let result = try await runner.enrich(workspaceID: fixture.workspaceID, relativePath: "plan.md")
        #expect(result == .applied)
        #expect(try onDisk(fixture).contains("twelve dollars per seat"))
        let entry = try #require(gate.activity[fixture.workspaceID]?.first)
        #expect(gate.pending(for: fixture.workspaceID).isEmpty)
        try gate.undo(entry.id, workspaceID: fixture.workspaceID)
        #expect(try onDisk(fixture) == inlineAIPlanText)
    }

    @Test("Off does nothing and sends nothing")
    func offDoesNothing() async throws {
        let fixture = try await InlineAIFixture(reply: enrichReply, approval: .off)
        defer { fixture.cleanUp() }
        let (runner, gate) = enricher(fixture)
        let result = try await runner.enrich(workspaceID: fixture.workspaceID, relativePath: "plan.md")
        guard case .nothing = result else {
            Issue.record("expected nothing, got \(result)")
            return
        }
        #expect(try onDisk(fixture) == inlineAIPlanText)
        #expect(gate.pending(for: fixture.workspaceID).isEmpty)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("a workspace with AI access None is never read for the model")
    func accessNone() async throws {
        let fixture = try await InlineAIFixture(reply: enrichReply, access: AIDataAccess.none, approval: .autoApprove)
        defer { fixture.cleanUp() }
        let (runner, _) = enricher(fixture)
        let result = try await runner.enrich(workspaceID: fixture.workspaceID, relativePath: "plan.md")
        guard case .nothing = result else {
            Issue.record("expected nothing, got \(result)")
            return
        }
        #expect(fixture.server.requests.isEmpty)
        #expect(try onDisk(fixture) == inlineAIPlanText)
    }

    @Test("the change carries the hash of the file as Fen read it, so a later edit is refused")
    func carriesTheBaseHash() async throws {
        let fixture = try await InlineAIFixture(reply: enrichReply, approval: .ask)
        defer { fixture.cleanUp() }
        let (runner, gate) = enricher(fixture)
        _ = try await runner.enrich(workspaceID: fixture.workspaceID, relativePath: "plan.md")
        let item = try #require(gate.pending(for: fixture.workspaceID).first)
        #expect(item.change.baseHash == ContentHash.of(Data(inlineAIPlanText.utf8)))
        try (inlineAIPlanText + "A late edit.\n").write(to: fixture.planURL, atomically: true, encoding: .utf8)
        #expect(throws: WriteError.targetChanged("plan.md")) { try gate.approve(item.id) }
        #expect(try onDisk(fixture) == inlineAIPlanText + "A late edit.\n")
    }

    @Test("a duplicate anchor line writes nothing")
    func duplicateAnchor() {
        let text = "- Same\n- Same\n"
        let edit = EditOperation.insertBelow(
            path: "a.md",
            insertions: [LineInsertion(anchor: "- Same", text: "    - fact")]
        )
        #expect(throws: WriteError.findNotUnique(count: 2)) { try EditPlanner.plan(edit, existing: text) }
    }

    @Test("insertBelow adds lines, is additive, and keeps every other line")
    func insertBelowIsAdditive() throws {
        let text = "# T\n\n- One\n- Two\n"
        let edit = EditOperation.insertBelow(path: "a.md", insertions: [
            LineInsertion(anchor: "- One", text: "    - first"),
            LineInsertion(anchor: "- Two", text: "    - second\n    - third"),
        ])
        let plan = try EditPlanner.plan(edit, existing: text)
        #expect(plan.tier == .additive)
        #expect(plan.newText == "# T\n\n- One\n    - first\n- Two\n    - second\n    - third\n")
    }
}
