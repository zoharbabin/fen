@testable import FenCore
import Foundation
import Testing

@Suite("Resolve links and add stubs under the write rules (issue #11)", .serialized)
@MainActor
struct ClassificationLinkRunTests {
    @Test("Ask queues link rewrites with the match as evidence, and writes nothing")
    func askQueuesLinks() async throws {
        let fixture = try await ClassifyFixture()
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(summary.linkProposals == 3)
        let item = try #require(fixture.waiting("resolve-links", "meetings/retro.md"))
        #expect(item.tier == .replacing)
        #expect(item.change.basis?.method == "title")
        #expect(item.change.basis?.confidence == 0.95)
        #expect(item.change.basis?.evidence.contains("Jane Doe") == true)
        #expect(try fixture.text("meetings/retro.md") == ClassifyFixture.files["meetings/retro.md"])
    }

    @Test("a link rewrite needs the opt-in for resolve-links, even under Auto-approve")
    func linksNeedOptIn() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove)
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let item = try #require(fixture.waiting("resolve-links", "meetings/retro.md"))
        #expect(item.reason == .replacingNotOptedIn)
        #expect(try fixture.text("meetings/retro.md") == ClassifyFixture.files["meetings/retro.md"])
    }

    @Test("with the opt-in, an exact title applies and a part-of-a-name match waits")
    func optedInLinks() async throws {
        let fixture = try await ClassifyFixture(
            approval: .autoApprove, optInReplacing: ["resolve-links"], minConfidence: WritePolicy.defaultMinConfidence
        )
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let retro = try fixture.text("meetings/retro.md")
        #expect(retro.contains("\"[[Jane Doe]]\""))
        #expect(retro.contains("# Retro"))
        let kickoff = try #require(fixture.waiting("resolve-links", "meetings/kickoff.md"))
        #expect(kickoff.reason == .lowConfidence)
        #expect(kickoff.change.basis?.confidence == 0.7)
        #expect(try fixture.text("meetings/kickoff.md") == ClassifyFixture.files["meetings/kickoff.md"])
    }

    @Test("a name nobody has a note for becomes a stub in the people folder, and always waits")
    func stubQueues() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove, optInReplacing: ["resolve-links"])
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(summary.stubProposals == 1)
        let stub = try #require(fixture.waiting("create-stub", "people/Carla Ruiz.md"))
        #expect(stub.reason == .lowConfidence)
        #expect(stub.change.basis?.confidence == ClassificationRun.stubConfidence)
        #expect(!FileManager.default
            .fileExists(atPath: fixture.notes.root.appendingPathComponent("people/Carla Ruiz.md").path))
    }

    @Test("approving a stub creates the note once, and it is typed")
    func stubApproved() async throws {
        let fixture = try await ClassifyFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let stub = try #require(fixture.waiting("create-stub", "people/Carla Ruiz.md"))
        _ = try fixture.gate.approve(stub.id)
        let text = try fixture.text("people/Carla Ruiz.md")
        #expect(text.contains("type: Person"))
        #expect(text.contains("Carla Ruiz"))
    }

    @Test("a stub never overwrites a note that appeared after the run")
    func stubNeverOverwrites() async throws {
        let fixture = try await ClassifyFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let stub = try #require(fixture.waiting("create-stub", "people/Carla Ruiz.md"))
        try "Mine.\n".write(
            to: fixture.notes.root.appendingPathComponent("people/Carla Ruiz.md"), atomically: true, encoding: .utf8
        )
        #expect(throws: (any Error).self) { try fixture.gate.approve(stub.id) }
        #expect(try fixture.text("people/Carla Ruiz.md") == "Mine.\n")
    }

    @Test("an overwrite is Destructive and asks whatever its confidence")
    func overwriteAsks() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove, optInReplacing: ["classify"])
        defer { fixture.cleanUp() }
        let basis = ProposalBasis(method: "test", confidence: 1.0, detail: "d", evidence: "e")
        let change = try ProposedChange(
            workspaceID: fixture.workspaceID,
            operation: "classify",
            edit: .overwrite(path: "pasta.md", content: "Gone.\n"),
            scope: ["pasta.md"],
            baseHash: ContentHash.of(Data(#require(ClassifyFixture.files["pasta.md"]?.utf8))),
            provenance: Provenance(provider: "t", model: "t"),
            basis: basis
        )
        guard case let .pending(item) = try fixture.gate.submit(change) else {
            Issue.record("an overwrite was not queued")
            return
        }
        #expect(item.tier == .destructive)
        #expect(try fixture.text("pasta.md") == ClassifyFixture.files["pasta.md"])
    }

    @Test("approve counts as accepted, reject as dismissed, and an auto-apply as auto")
    func statsFollowOutcomes() async throws {
        let fixture = try await ClassifyFixture(approval: .ask)
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let accept = try #require(fixture.waiting("classify", "pasta.md"))
        let dismiss = try #require(fixture.waiting("create-stub", "people/Carla Ruiz.md"))
        _ = try fixture.gate.approve(accept.id)
        fixture.gate.reject(dismiss.id)
        let stats = fixture.gate.stats(for: fixture.workspaceID)
        #expect(stats.operations["classify"]?.accepted == 1)
        #expect(stats.operations["create-stub"]?.dismissed == 1)
        #expect(stats.operations["classify"]?.auto == 0)
    }

    @Test("auto-applied changes are counted as auto")
    func statsAuto() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove)
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        #expect((fixture.gate.stats(for: fixture.workspaceID).operations["classify"]?.auto ?? 0) >= 1)
    }

    @Test("a note with no fields to link is left alone")
    func noLinkFields() async throws {
        let fixture = try await ClassifyFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        #expect(fixture.waiting("resolve-links", "people/Jane Doe.md") == nil)
        #expect(fixture.waiting("resolve-links", "pasta.md") == nil)
    }
}
