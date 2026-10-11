@testable import FenCore
import Foundation
import Testing

/// A change that names a branch (`branchAs`) never auto-applies into your files (issue #94).
@MainActor
@Suite("Write gate: changes meant for a branch")
struct WriteGateBranchAsTests {
    private func autoSettings(mode: AgentBranchMode = .perAgent) -> WorkspaceSettings {
        WorkspaceSettings(
            approvalMode: .autoApprove,
            writePolicy: WritePolicy(autoApproveConfirmed: true, autoApproveReplacing: ["resolve-conflict"]),
            agentBranches: mode
        )
    }

    private func change(_ harness: GateHarness, invokedByUser: Bool = false) throws -> ProposedChange {
        let current = try Data(contentsOf: harness.folder.root.appendingPathComponent("a.md"))
        return ProposedChange(
            workspaceID: harness.workspaceID,
            operation: "resolve-conflict",
            edit: .replaceText(path: "a.md", find: "One.", with: "Two."),
            scope: ["a.md"],
            baseHash: ContentHash.of(current),
            invokedByUser: invokedByUser,
            provenance: Provenance(provider: "Fen", model: "conflicts"),
            branchAs: "Conflicts"
        )
    }

    @Test func autoApproveCommitsToTheBranchAndLeavesYourFiles() async throws {
        let harness = try GateHarness.agents(autoSettings())
        defer { harness.cleanUp() }
        let head = try harness.git("rev-parse", "HEAD")
        let entry = try await harness.applied(harness.gate.submitRouted(change(harness)))

        #expect(entry.branch == "fen/conflicts")
        #expect(harness.text("a.md") == "# A\n\nOne.\n")
        #expect(try harness.git("show", "fen/conflicts:a.md") == "# A\n\nTwo.\n")
        #expect(try harness.git("rev-parse", "HEAD") == head)
        #expect(try harness.git("log", "-1", "--format=%B", "fen/conflicts").contains("Fen-Agent: Conflicts"))
    }

    @Test func withoutGitItAsksInsteadOfWritingYourFiles() async throws {
        let harness = try GateHarness(files: ["a.md": "# A\n\nOne.\n"], settings: autoSettings())
        defer { harness.cleanUp() }
        let outcome = try await harness.gate.submitRouted(change(harness))
        guard case let .pending(item) = outcome else { throw WriteError.unknownChange }
        #expect(item.reason == .noBranch)
        #expect(harness.text("a.md") == "# A\n\nOne.\n")
    }

    @Test func inPlaceModeAlsoAsks() async throws {
        let harness = try GateHarness.agents(autoSettings(mode: .inPlace))
        defer { harness.cleanUp() }
        guard case let .pending(item) = try await harness.gate.submitRouted(change(harness)) else {
            throw WriteError.unknownChange
        }
        #expect(item.reason == .noBranch)
        #expect(harness.text("a.md") == "# A\n\nOne.\n")
    }

    @Test func approvingAWaitingChangeWithoutAnyBranchWritesItInPlace() async throws {
        let harness = try GateHarness(files: ["a.md": "# A\n\nOne.\n"], settings: autoSettings())
        defer { harness.cleanUp() }
        guard case let .pending(item) = try await harness.gate.submitRouted(change(harness)) else {
            throw WriteError.unknownChange
        }
        try await harness.gate.approveRouted(item.id)
        #expect(harness.text("a.md") == "# A\n\nTwo.\n")
    }

    @Test func undoOpensTheBranchTheChangeWentTo() async throws {
        let harness = try GateHarness.agents(autoSettings())
        defer { harness.cleanUp() }
        let entry = try await harness.applied(harness.gate.submitRouted(change(harness)))
        try await harness.gate.undoRouted(entry.id, workspaceID: harness.workspaceID)
        #expect(try harness.git("show", "fen/conflicts:a.md") == "# A\n\nOne.\n")
        #expect(try harness.git("rev-list", "--count", "HEAD..fen/conflicts") == "2\n")
    }

    @Test func aChangeWithoutBranchAsIsUnaffected() async throws {
        let harness = try GateHarness(files: ["a.md": "# A\n\nOne.\n"], settings: autoSettings())
        defer { harness.cleanUp() }
        var plain = try change(harness)
        plain.branchAs = nil
        _ = try await harness.applied(harness.gate.submitRouted(plain))
        #expect(harness.text("a.md") == "# A\n\nTwo.\n")
    }
}
