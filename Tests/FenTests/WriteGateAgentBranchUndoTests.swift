@testable import FenCore
import Foundation
import Testing

@MainActor
@Suite("Write gate: undo and destructive changes on agent branches (issue #93)")
struct WriteGateAgentBranchUndoTests {
    private func approved(_ harness: GateHarness, _ edit: EditOperation, as client: String = "Claude") async throws
        -> ActivityEntry {
        let change = try await harness.proposal(edit, as: client)
        guard case let .pending(item) = try await harness.gate.submitRouted(change) else {
            Issue.record("Expected \(edit.name) to wait for approval")
            throw WriteError.unknownChange
        }
        return try await harness.gate.approveRouted(item.id)
    }

    @Test func undoIsANewCommitSoTheHistoryKeepsBoth() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let entry = try await harness.applied(harness.gate.submitRouted(
            harness.proposal(.append(path: "a.md", text: "Oops.\n"))
        ))
        let undone = try await harness.gate.undoRouted(entry.id, workspaceID: harness.workspaceID)

        #expect(undone.isUndone)
        #expect(try harness.git("show", "fen/claude:a.md") == "# A\n\nOne.\n")
        #expect(try harness.git("rev-list", "--count", "HEAD..fen/claude") == "2\n")
        let log = try harness.git("log", "-1", "--format=%s%n%b", "fen/claude")
        #expect(log.contains("Undo: append a.md"))
        #expect(log.contains("Fen-Undo-Of: \(entry.id.uuidString.lowercased())"))
        #expect(harness.text("a.md") == "# A\n\nOne.\n")
        await #expect(throws: WriteError.alreadyUndone) {
            try await harness.gate.undoRouted(entry.id, workspaceID: harness.workspaceID)
        }
    }

    @Test func undoRefusesWhenTheFileChangedAfterwards() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let first = try await harness.applied(harness.gate.submitRouted(
            harness.proposal(.append(path: "a.md", text: "One.\n"))
        ))
        try await harness.gate.submitRouted(harness.proposal(.append(path: "a.md", text: "Two.\n")))
        let tip = try harness.git("rev-parse", "fen/claude")
        await #expect(throws: WriteError.changedSinceApply("a.md")) {
            try await harness.gate.undoRouted(first.id, workspaceID: harness.workspaceID)
        }
        #expect(try harness.git("rev-parse", "fen/claude") == tip)
    }

    @Test func undoingACreateRemovesTheFileFromTheBranch() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let entry = try await harness.applied(harness.gate.submitRouted(
            harness.proposal(.createFile(path: "new.md", content: "x\n"), base: .some(nil))
        ))
        #expect(try harness.git("ls-tree", "--name-only", "fen/claude").contains("new.md"))
        try await harness.gate.undoRouted(entry.id, workspaceID: harness.workspaceID)
        #expect(try !harness.git("ls-tree", "--name-only", "fen/claude").contains("new.md"))
    }

    @Test func aDeleteWaitsThenRemovesTheFileOnlyFromTheBranchAndUndoRestoresIt() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let entry = try await approved(harness, .delete(path: "b.md"))
        #expect(entry.tier == .destructive)
        #expect(harness.exists("b.md"))
        #expect(try !harness.git("ls-tree", "--name-only", "fen/claude").contains("b.md"))

        try await harness.gate.undoRouted(entry.id, workspaceID: harness.workspaceID)
        #expect(try harness.git("show", "fen/claude:b.md") == "# B\n")
    }

    @Test func aMoveRenamesOnTheBranchAndUndoMovesItBack() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let entry = try await approved(harness, .move(from: "b.md", to: "docs/b.md"))
        #expect(entry.toPath == "docs/b.md")
        let names = try harness.git("ls-tree", "-r", "--name-only", "fen/claude")
        #expect(names.contains("docs/b.md") && !names.contains("\nb.md"))
        #expect(harness.exists("b.md") && !harness.exists("docs/b.md"))

        try await harness.gate.undoRouted(entry.id, workspaceID: harness.workspaceID)
        #expect(try harness.git("show", "fen/claude:b.md") == "# B\n")
        #expect(try !harness.git("ls-tree", "-r", "--name-only", "fen/claude").contains("docs/b.md"))
    }

    @Test func aMoveOntoAnExistingFileIsRefused() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        await #expect(throws: WriteError.alreadyExists("a.md")) {
            try await harness.gate.submitRouted(harness.proposal(.move(from: "b.md", to: "a.md")))
        }
    }

    @Test func revertingARunUndoesEveryChangeNewestFirst() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let run = UUID()
        try await harness.gate.submitRouted(harness.proposal(.append(path: "a.md", text: "1\n"), run: run))
        try await harness.gate.submitRouted(harness.proposal(.append(path: "b.md", text: "2\n"), run: run))
        let result = await harness.gate.revertRunRouted(run, workspaceID: harness.workspaceID)
        #expect(result.undone == 2 && result.failures.isEmpty)
        #expect(try harness.git("show", "fen/claude:a.md") == "# A\n\nOne.\n")
        #expect(try harness.git("show", "fen/claude:b.md") == "# B\n")
    }

    @Test func undoOfAnInPlaceChangeStillWorksThroughTheRoutedCall() async throws {
        let harness = try GateHarness.agents(autoSettings())
        defer { harness.cleanUp() }
        let entry = try await harness.applied(harness.gate.submitRouted(
            harness.change(.append(path: "a.md", text: "Local.\n"), operation: "enrich")
        ))
        try await harness.gate.undoRouted(entry.id, workspaceID: harness.workspaceID)
        #expect(harness.text("a.md") == "# A\n\nOne.\n")
    }

    @Test func theLogAndPreImagesSurviveARestart() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let entry = try await harness.applied(harness.gate.submitRouted(
            harness.proposal(.append(path: "a.md", text: "Kept.\n"))
        ))
        let restarted = harness.restartedGate()
        let loaded = try #require(restarted.entries(for: harness.workspaceID).first)
        #expect(loaded.id == entry.id && loaded.branch == "fen/claude" && loaded.commit == entry.commit)
    }
}
