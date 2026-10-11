@testable import FenCore
import Foundation
import Testing

@Suite("Fix a conflict through the write gate (issue #94)", .serialized)
@MainActor
struct ConflictResolverTests {
    static let rewrite = "We ship the release every 4 weeks on Monday, with no exceptions."

    private func changeWaiting(_ fixture: ConflictFixture) throws -> WriteGate.Pending {
        try #require(fixture.gate.pending(for: fixture.workspaceID).first { $0.change.operation == "resolve-conflict" })
    }

    @Test("By default a fix only asks. Nothing is written, nothing is committed")
    func defaultNeverWrites() async throws {
        let fixture = try await ConflictFixture(provider: .local, reply: Self.rewrite, useGit: true)
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let before = try fixture.listing()
        let head = try fixture.notes.git("rev-parse", "HEAD")
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .passage
        )
        #expect(result == .queued)
        #expect(try fixture.listing() == before)
        #expect(try fixture.notes.git("rev-parse", "HEAD") == head)
        #expect(try fixture.notes.git("branch", "--list", "fen/*").isEmpty)
        let item = try changeWaiting(fixture)
        #expect(item.reason == .modeIsAsk)
        #expect(item.change.branchAs == "Conflicts")
        #expect(item.change.invokedByUser == false)
        #expect(item.change.basis?.method == "conflict")
        #expect(fixture.gate.entries(for: fixture.workspaceID).isEmpty)
    }

    @Test("Auto-approve alone still asks, until the workspace opts resolve-conflict in")
    func autoApproveNeedsOptIn() async throws {
        let fixture = try await ConflictFixture(
            provider: .local,
            reply: Self.rewrite,
            approval: .autoApprove,
            useGit: true
        )
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .passage
        )
        #expect(result == .queued)
        #expect(try changeWaiting(fixture).reason == .replacingNotOptedIn)
        #expect(try fixture.text("docs/policy.md") == ConflictFixture.policy)
    }

    @Test("With the opt-in and a git branch, the fix is its own commit on fen/conflicts and your files stay")
    func autoApproveCommitsToBranch() async throws {
        let fixture = try await ConflictFixture(
            provider: .local, reply: Self.rewrite, approval: .autoApprove, optInReplacing: ["resolve-conflict"],
            useGit: true
        )
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let head = try fixture.notes.git("rev-parse", "HEAD")
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .passage
        )
        #expect(result == .applied)
        #expect(try fixture.text("docs/policy.md") == ConflictFixture.policy)
        #expect(try fixture.notes.git("rev-parse", "HEAD") == head)
        #expect(try fixture.notes.git("rev-list", "--count", "HEAD..fen/conflicts") == "1\n")
        let fixed = try fixture.notes.git("show", "fen/conflicts:docs/policy.md")
        #expect(fixed.contains(Self.rewrite))
        #expect(try fixture.notes.git("log", "-1", "--format=%B", "fen/conflicts").contains("Fen-Agent: Conflicts"))
        // Fen never merges that branch.
        #expect(try fixture.notes.git("branch", "--merged", "HEAD").contains("fen/conflicts") == false)
        let entry = try #require(fixture.gate.entries(for: fixture.workspaceID).first)
        #expect(entry.branch == "fen/conflicts")
        #expect(entry.agent == "Conflicts")
    }

    @Test("With the opt-in but no git branch, the fix asks")
    func noBranchAsks() async throws {
        let fixture = try await ConflictFixture(
            provider: .local, reply: Self.rewrite, approval: .autoApprove, optInReplacing: ["resolve-conflict"]
        )
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .passage
        )
        #expect(result == .queued)
        #expect(try changeWaiting(fixture).reason == .noBranch)
        #expect(try fixture.text("docs/policy.md") == ConflictFixture.policy)
    }

    @Test("Approving the waiting fix writes the passage and nothing else")
    func approveWrites() async throws {
        let fixture = try await ConflictFixture(provider: .local, reply: Self.rewrite)
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        _ = try await fixture.resolver.resolve(flag, workspaceID: fixture.workspaceID, keep: .changed, scope: .passage)
        _ = try await fixture.gate.approveRouted(changeWaiting(fixture).id)
        #expect(try fixture.text("docs/policy.md") == "# Policy\n\n\(Self.rewrite)\n")
        #expect(try fixture.text("docs/handbook.md") == ConflictFixture.handbook)
    }

    @Test("Keeping the other side rewrites the changed note")
    func keepOther() async throws {
        let fixture = try await ConflictFixture(
            provider: .local,
            reply: "We ship the release every 2 weeks on Thursday, with no exceptions."
        )
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        _ = try await fixture.resolver.resolve(flag, workspaceID: fixture.workspaceID, keep: .other, scope: .passage)
        let item = try changeWaiting(fixture)
        #expect(item.change.edit.primaryPath == "docs/handbook.md")
        #expect(item.change.scope == ["docs/handbook.md"])
    }

    @Test("Document scope rewrites the whole body and keeps the front matter")
    func documentScope() async throws {
        let files = [
            "docs/policy.md": "---\ntype: Policy\n---\n"
                + "We ship the release every 2 weeks on Thursday, with no exceptions.\n\n"
                + "The release also goes out every 2 weeks to partners.\n",
            "docs/handbook.md": ConflictFixture.handbook,
        ]
        let reply = "We ship the release every 4 weeks on Monday.\n\nThe release also goes out every 4 weeks to partners."
        let fixture = try await ConflictFixture(provider: .local, reply: reply, files: files)
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .document
        )
        #expect(result == .queued)
        _ = try await fixture.gate.approveRouted(changeWaiting(fixture).id)
        let text = try fixture.text("docs/policy.md")
        #expect(text.hasPrefix("---\ntype: Policy\n---\n"))
        #expect(text.contains("every 4 weeks to partners"))
        #expect(!text.contains("2 weeks"))
    }

    @Test("A draft that adds a link is dropped and nothing is queued")
    func badDraft() async throws {
        let fixture = try await ConflictFixture(provider: .local, reply: Self.rewrite + " See https://evil.example/x")
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .passage
        )
        guard case let .nothing(reason) = result else { throw WriteError.unknownChange }
        #expect(reason.contains("link or web address"))
        #expect(fixture.gate.pending(for: fixture.workspaceID).isEmpty)
        #expect(fixture.state().flags.first?.resolution == nil)
    }

    @Test("A passage that changed since it was flagged is not rewritten")
    func stalePassage() async throws {
        let fixture = try await ConflictFixture(provider: .local, reply: Self.rewrite)
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        try fixture.notes.write("docs/policy.md", "# Policy\n\nSomething else entirely, long enough to be a passage.\n")
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .passage
        )
        guard case let .nothing(reason) = result else { throw WriteError.unknownChange }
        #expect(reason.contains("changed since"))
        #expect(fixture.gate.pending(for: fixture.workspaceID).isEmpty)
    }

    @Test("A workspace that keeps notes from a remote provider gets no fix drafted")
    func remoteBlocked() async throws {
        let fixture = try await ConflictFixture(provider: .remote, reply: Self.rewrite)
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .passage
        )
        guard case .nothing = result else { throw WriteError.unknownChange }
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("The flag follows its fix: waiting, resolved, open again after undo, open again after reject")
    func statusFollowsGate() async throws {
        let fixture = try await ConflictFixture(
            provider: .local, reply: Self.rewrite, approval: .autoApprove, optInReplacing: ["resolve-conflict"],
            useGit: true
        )
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let resolver = fixture.resolver
        func current() throws -> ConflictFlag {
            try #require(fixture.state().flags.first)
        }
        #expect(try resolver.status(of: current(), in: fixture.workspaceID) == .open)

        _ = try await resolver.resolve(flag, workspaceID: fixture.workspaceID, keep: .changed, scope: .passage)
        #expect(try resolver.status(of: current(), in: fixture.workspaceID) == .resolved)

        try await resolver.revert(current(), in: fixture.workspaceID)
        #expect(try resolver.status(of: current(), in: fixture.workspaceID) == .open)
        #expect(try fixture.notes.git("show", "fen/conflicts:docs/policy.md") == ConflictFixture.policy)
    }

    @Test("A rejected fix opens the flag again")
    func rejectReopens() async throws {
        let fixture = try await ConflictFixture(provider: .local, reply: Self.rewrite)
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        _ = try await fixture.resolver.resolve(flag, workspaceID: fixture.workspaceID, keep: .changed, scope: .passage)
        let saved = try #require(fixture.state().flags.first)
        #expect(fixture.resolver.status(of: saved, in: fixture.workspaceID) == .waiting)
        try fixture.gate.reject(changeWaiting(fixture).id)
        #expect(fixture.resolver.status(of: saved, in: fixture.workspaceID) == .open)
    }

    @Test("A whole-note rewrite that changes most of the note asks, even with the opt-in")
    func bigRewriteAsks() async throws {
        let fixture = try await ConflictFixture(
            provider: .local, reply: "We ship the release every 4 weeks on Monday, with no exceptions at all.",
            approval: .autoApprove, optInReplacing: ["resolve-conflict"], useGit: true
        )
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .document
        )
        #expect(result == .queued)
        #expect(try changeWaiting(fixture).reason == .overCap)
    }

    @Test("Undo reverts a whole-note fix too")
    func undoDocumentScope() async throws {
        let filler = String(
            repeating: "The team reviews every release note before it goes out to the partners. ",
            count: 6
        )
        let original = "# Policy\n\nWe ship the release every 2 weeks on Thursday, with no exceptions.\n\n\(filler)\n"
        let fixed = original.replacingOccurrences(of: "2 weeks on Thursday", with: "4 weeks on Monday")
        let fixture = try await ConflictFixture(
            provider: .local, reply: fixed,
            approval: .autoApprove, optInReplacing: ["resolve-conflict"], useGit: true,
            files: ["docs/policy.md": original, "docs/handbook.md": ConflictFixture.handbook]
        )
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let result = try await fixture.resolver.resolve(
            flag,
            workspaceID: fixture.workspaceID,
            keep: .changed,
            scope: .document
        )
        #expect(result == .applied)
        #expect(try fixture.notes.git("show", "fen/conflicts:docs/policy.md").contains("4 weeks on Monday"))
        try await fixture.resolver.revert(fixture.state().flags[0], in: fixture.workspaceID)
        #expect(try fixture.notes.git("show", "fen/conflicts:docs/policy.md") == original)
    }

    @Test("Dismiss, reopen and clear change only the state file")
    func dismissReopenClear() async throws {
        let fixture = try await ConflictFixture()
        defer { fixture.cleanUp() }
        let flag = try fixture.plantFlag()
        let before = try fixture.listing()
        try fixture.resolver.dismiss(flag.id, in: fixture.workspaceID)
        #expect(fixture.resolver.status(of: fixture.state().flags[0], in: fixture.workspaceID) == .dismissed)
        try fixture.resolver.reopen(flag.id, in: fixture.workspaceID)
        #expect(fixture.resolver.status(of: fixture.state().flags[0], in: fixture.workspaceID) == .open)
        try fixture.resolver.clear(flag.id, in: fixture.workspaceID)
        #expect(fixture.state().flags.isEmpty)
        #expect(try fixture.listing() == before)
    }
}
