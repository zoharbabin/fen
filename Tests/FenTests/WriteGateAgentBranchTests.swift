@testable import FenCore
import Foundation
import Testing

extension GateHarness {
    /// A gate that commits agent changes with the system git.
    static func agents(
        _ settings: WorkspaceSettings = agentSettings("Claude", "Codex"),
        files: [String: String] = ["a.md": "# A\n\nOne.\n", "b.md": "# B\n"]
    ) throws -> GateHarness {
        try GateHarness(files: files, settings: settings, git: true, agentBranches: AgentBranches(git: GitFixture.tool))
    }

    /// An agent's proposal, based on `base` (the hash it read) or on what the branch holds now.
    func proposal(
        _ edit: EditOperation,
        as client: String = "Claude",
        base: String?? = nil,
        run: UUID? = nil
    ) async throws -> ProposedChange {
        let hash: String? = switch base {
        case let .some(value): value
        case .none: try await gate.agentRead(workspaceID: workspaceID, path: edit.primaryPath, client: client)
            .map { ContentHash.of($0.data) }
        }
        return ProposedChange(
            workspaceID: workspaceID,
            runID: run ?? UUID(),
            operation: "mcp.\(edit.name)",
            client: client,
            edit: edit,
            scope: Set(edit.paths),
            baseHash: hash,
            provenance: Provenance(provider: "mcp", model: client)
        )
    }

    func git(_ arguments: String...) throws -> String {
        try folder.git(arguments)
    }

    func applied(_ outcome: WriteGate.Outcome) throws -> ActivityEntry {
        guard case let .applied(entry) = outcome else {
            Issue.record("Expected applied, got \(outcome)")
            throw WriteError.unknownChange
        }
        return entry
    }
}

@MainActor
@Suite("Write gate: agent branches (issue #93)")
struct WriteGateAgentBranchTests {
    @Test func anAgentChangeIsCommittedToItsBranchAndYourFilesStayAsTheyWere() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        try harness.folder.write("a.md", "# A\n\nMy unsaved edit.\n")
        let head = try harness.git("rev-parse", "HEAD")

        let outcome = try await harness.gate.submitRouted(harness.proposal(.append(
            path: "a.md",
            text: "From Claude.\n"
        )))
        let entry = try harness.applied(outcome)

        #expect(entry.branch == "fen/claude")
        #expect(entry.commit?.count == 40)
        #expect(harness.text("a.md") == "# A\n\nMy unsaved edit.\n")
        #expect(try harness.git("show", "fen/claude:a.md") == "# A\n\nOne.\nFrom Claude.\n")
        #expect(try harness.git("rev-parse", "HEAD") == head)
        #expect(try harness.git("status", "--porcelain") == " M a.md\n")
        #expect(harness.gate.entries(for: harness.workspaceID).map(\.id) == [entry.id])
    }

    @Test func theCommitRecordsWhoWhyAndWhichActivityEntry() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let run = UUID()
        let entry = try await harness.applied(harness.gate.submitRouted(
            harness.proposal(.append(path: "a.md", text: "x\n"), run: run)
        ))
        let message = try harness.git("log", "-1", "--format=%an <%ae>%n%s%n%b", "fen/claude")
        #expect(message.contains("Claude <agent@fen.invalid>"))
        #expect(message.contains("append: a.md"))
        #expect(message.contains("Fen-Agent: Claude"))
        #expect(message.contains("Fen-Operation: mcp.append"))
        #expect(message.contains("Fen-Run: \(run.uuidString.lowercased())"))
        #expect(message.contains("Fen-Activity: \(entry.id.uuidString.lowercased())"))
        #expect(message.contains("Fen-Approved-By: auto"))
        #expect(message.contains("AI-Assisted-By: mcp Claude"))
    }

    @Test func aChangeFromInsideFenStillWritesInPlace() async throws {
        let harness = try GateHarness.agents(autoSettings())
        defer { harness.cleanUp() }
        let change = try harness.change(.append(path: "a.md", text: "In app.\n"), operation: "enrich")
        let entry = try await harness.applied(harness.gate.submitRouted(change))
        #expect(entry.branch == nil)
        #expect(harness.text("a.md")?.hasSuffix("In app.\n") == true)
        #expect(try harness.git("branch", "--list", "fen/*").isEmpty)
    }

    @Test func inPlaceModeWritesYourFiles() async throws {
        let harness = try GateHarness.agents(agentSettings("Claude", mode: .inPlace))
        defer { harness.cleanUp() }
        let entry = try await harness.applied(harness.gate.submitRouted(
            harness.proposal(.append(path: "a.md", text: "Direct.\n"), base: .some(
                harness.gate.contentHash(workspaceID: harness.workspaceID, relativePath: "a.md")
            ))
        ))
        #expect(entry.branch == nil)
        #expect(harness.text("a.md")?.hasSuffix("Direct.\n") == true)
    }

    @Test func aFolderThatIsNotARepositoryKeepsTheOrdinaryPath() async throws {
        let harness = try GateHarness(settings: agentSettings("Claude"))
        defer { harness.cleanUp() }
        let hash = try harness.gate.contentHash(workspaceID: harness.workspaceID, relativePath: "a.md")
        let entry = try await harness.applied(harness.gate.submitRouted(
            harness.proposal(.append(path: "a.md", text: "Plain.\n"), base: .some(hash))
        ))
        #expect(entry.branch == nil)
        #expect(harness.text("a.md")?.hasSuffix("Plain.\n") == true)
    }

    @Test func aClientWithoutARuleStillAsksAndApprovalCommitsToTheBranch() async throws {
        let harness = try GateHarness.agents(agentSettings("Codex"))
        defer { harness.cleanUp() }
        let change = try await harness.proposal(.append(path: "a.md", text: "Later.\n"), as: "Claude")
        guard case let .pending(item) = try await harness.gate.submitRouted(change) else {
            Issue.record("Expected a waiting change")
            return
        }
        #expect(harness.gate.pending(for: harness.workspaceID).count == 1)
        #expect(try harness.git("branch", "--list", "fen/*").isEmpty)

        let entry = try await harness.gate.approveRouted(item.id)
        #expect(entry.branch == "fen/claude")
        #expect(entry.approvedBy == .user)
        #expect(harness.text("a.md") == "# A\n\nOne.\n")
        #expect(try harness.git("show", "fen/claude:a.md").hasSuffix("Later.\n"))
        #expect(harness.gate.pending(for: harness.workspaceID).isEmpty)
    }

    @Test func aFileGitDoesNotTrackIsEditedInPlaceAndAsksFirst() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        try harness.folder.write("draft.md", "# Draft\n")
        let hash = try harness.gate.contentHash(workspaceID: harness.workspaceID, relativePath: "draft.md")
        let entry = try await harness.applied(harness.gate.submitRouted(
            harness.proposal(.append(path: "draft.md", text: "more\n"), base: .some(hash))
        ))
        #expect(entry.branch == nil)
        #expect(harness.text("draft.md") == "# Draft\nmore\n")
    }

    // MARK: - Reading

    @Test func anAgentReadsWhatItsBranchBuildsOn() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let id = harness.workspaceID
        try harness.folder.write("a.md", "# A\n\nDirty on disk.\n")
        let first = try #require(await harness.gate.agentRead(workspaceID: id, path: "a.md", client: "Claude"))
        #expect(String(decoding: first.data, as: UTF8.self) == "# A\n\nOne.\n")
        #expect(first.branch == "fen/claude")

        try await harness.gate.submitRouted(harness.proposal(.append(path: "a.md", text: "Two.\n")))
        let second = try #require(await harness.gate.agentRead(workspaceID: id, path: "a.md", client: "Claude"))
        #expect(String(decoding: second.data, as: UTF8.self) == "# A\n\nOne.\nTwo.\n")
        // Another agent has its own view.
        let other = try #require(await harness.gate.agentRead(workspaceID: id, path: "a.md", client: "Codex"))
        #expect(String(decoding: other.data, as: UTF8.self) == "# A\n\nOne.\n")
    }

    @Test func untrackedHiddenAndOutsidePathsAreNotReadFromABranch() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let id = harness.workspaceID
        try harness.folder.write("draft.md", "x")
        #expect(try await harness.gate.agentRead(workspaceID: id, path: "draft.md", client: "Claude") == nil)
        for path in [".gitignore", "../x.md", "/etc/passwd", "a/../a.md"] {
            await #expect(throws: WriteError.invalidPath(path)) {
                _ = try await harness.gate.agentRead(workspaceID: id, path: path, client: "Claude")
            }
        }
    }

    @Test func aTrackedFileTheWorkspaceLeavesOutIsNotReadFromABranch() async throws {
        var settings = agentSettings("Claude")
        settings.excludeGlobs = ["private/**"]
        let harness = try GateHarness.agents(settings, files: [
            "a.md": "# A\n", "private/p.md": "# Private\n", "data.json": "{}\n",
        ])
        defer { harness.cleanUp() }
        try harness.folder.write("build/out.md", "# Ignored\n")
        try harness.git("add", "-f", "build/out.md")
        try harness.git("commit", "-q", "-m", "force")
        let id = harness.workspaceID
        #expect(try await harness.gate.agentRead(workspaceID: id, path: "a.md", client: "Claude") != nil)
        for path in ["private/p.md", "build/out.md", "data.json"] {
            await #expect(throws: WriteError.invalidPath(path)) {
                _ = try await harness.gate.agentRead(workspaceID: id, path: path, client: "Claude")
            }
        }
    }

    @Test func afterYouMergeTheBranchTheAgentBuildsOnYourHistory() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        try await harness.gate.submitRouted(harness.proposal(.append(path: "a.md", text: "Agent.\n")))
        try harness.git("merge", "-q", "--no-edit", "fen/claude")
        try harness.folder.write("b.md", "# B\n\nYours.\n")
        try harness.git("commit", "-q", "-am", "yours")

        try await harness.gate.submitRouted(harness.proposal(.append(path: "a.md", text: "Again.\n")))
        // The branch moved up to your commit first, so the merge is a fast-forward and holds both.
        #expect(try harness.git("show", "fen/claude:b.md") == "# B\n\nYours.\n")
        #expect(try harness.git("show", "fen/claude:a.md") == "# A\n\nOne.\nAgent.\nAgain.\n")
        #expect(try harness.git("rev-list", "--count", "HEAD..fen/claude") == "1\n")
    }

    // MARK: - Safety checks still apply

    @Test func aStaleBaseHashIsRefused() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let stale = ContentHash.of(Data("# A\n\nOne.\n".utf8))
        try await harness.gate.submitRouted(harness.proposal(.append(path: "a.md", text: "First.\n")))
        await #expect(throws: WriteError.targetChanged("a.md")) {
            try await harness.gate.submitRouted(harness.proposal(
                .append(path: "a.md", text: "Second.\n"),
                base: .some(stale)
            ))
        }
        #expect(try harness.git("show", "fen/claude:a.md") == "# A\n\nOne.\nFirst.\n")
    }

    @Test func scopeAndPathRulesStillApply() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        var change = try await harness.proposal(.append(path: "a.md", text: "x\n"))
        change.scope = ["b.md"]
        await #expect(throws: WriteError.outsideScope("a.md")) { try await harness.gate.submitRouted(change) }
        for path in ["../x.md", ".secret.md", ".env"] {
            await #expect(throws: WriteError.invalidPath(path)) {
                try await harness.gate.submitRouted(harness.proposal(
                    .createFile(path: path, content: "x"),
                    base: .some(nil)
                ))
            }
        }
        #expect(try harness.git("branch", "--list", "fen/*").isEmpty)
    }

    @Test func aNewFileMustNotExistOnDiskOrOnTheBranch() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        try harness.folder.write("draft.md", "mine")
        for path in ["a.md", "draft.md"] {
            await #expect(throws: WriteError.alreadyExists(path)) {
                try await harness.gate.submitRouted(harness.proposal(
                    .createFile(path: path, content: "x"),
                    base: .some(nil)
                ))
            }
        }
    }

    // MARK: - Collisions

    @Test func twoAgentsEditingOneFileKeepBothChangesOnSeparateBranches() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let claude = try await harness.proposal(.append(path: "a.md", text: "Claude was here.\n"), as: "Claude")
        let codex = try await harness.proposal(.append(path: "b.md", text: "Codex was here.\n"), as: "Codex")
        async let first = harness.gate.submitRouted(claude)
        async let second = harness.gate.submitRouted(codex)
        _ = try await (first, second)

        try harness.git("merge", "-q", "--no-edit", "fen/claude", "fen/codex")
        #expect(harness.text("a.md")?.contains("Claude was here.") == true)
        #expect(harness.text("b.md")?.contains("Codex was here.") == true)
    }

    @Test func twoAgentsAppendingToTheSameFileLoseNothingAndGitSeesTheOverlap() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let claude = try await harness.proposal(.append(path: "a.md", text: "Claude.\n"), as: "Claude")
        let codex = try await harness.proposal(.append(path: "a.md", text: "Codex.\n"), as: "Codex")
        async let first = harness.gate.submitRouted(claude)
        async let second = harness.gate.submitRouted(codex)
        _ = try await (first, second)

        #expect(try harness.git("show", "fen/claude:a.md").hasSuffix("Claude.\n"))
        #expect(try harness.git("show", "fen/codex:a.md").hasSuffix("Codex.\n"))
        // Both survive on their branches. Merging the second one reports a conflict instead of
        // dropping either change. What a collision means is issue #94's job.
        try harness.git("merge", "-q", "--no-edit", "fen/claude")
        let merge = try harness.git("merge", "--no-edit", "fen/codex")
        #expect(merge.contains("CONFLICT"))
        try harness.git("merge", "--abort")
    }

    @Test func oneAgentWritingTheSameFileConcurrentlyNeverLosesAWrite() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let id = harness.workspaceID
        // Every writer read the file as it was, so only the first can win. The rest must fail.
        let original = ContentHash.of(Data("# A\n\nOne.\n".utf8))
        var tasks: [Task<WriteGate.Outcome, Error>] = []
        for index in 0 ..< 6 {
            let change = try await harness.proposal(
                .append(path: "a.md", text: "Line \(index).\n"),
                base: .some(original)
            )
            tasks.append(Task { try await harness.gate.submitRouted(change) })
        }
        var results: [Result<WriteGate.Outcome, Error>] = []
        for task in tasks {
            await results.append(task.result)
        }
        let wins = results.filter {
            if case .success = $0 {
                true
            } else {
                false
            }
        }
        #expect(wins.count == 1)
        for case let .failure(error) in results {
            #expect(error as? WriteError == .targetChanged("a.md"))
        }
        let read = try #require(await harness.gate.agentRead(workspaceID: id, path: "a.md", client: "Claude"))
        #expect(String(decoding: read.data, as: UTF8.self).components(separatedBy: "Line ").count == 2)
    }

    @Test func writersThatReReadBeforeEachWriteAllLand() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        let id = harness.workspaceID
        var writers: [Task<Bool, Never>] = []
        for index in 0 ..< 6 {
            writers.append(Task {
                for _ in 0 ..< 20 {
                    guard let change = try? await harness.proposal(.append(path: "a.md", text: "Line \(index).\n"))
                    else { continue }
                    if await (try? harness.gate.submitRouted(change)) != nil {
                        return true
                    }
                }
                return false
            })
        }
        for writer in writers {
            #expect(await writer.value, "A writer never landed")
        }
        let read = try #require(await harness.gate.agentRead(workspaceID: id, path: "a.md", client: "Claude"))
        let text = String(decoding: read.data, as: UTF8.self)
        for index in 0 ..< 6 {
            #expect(text.contains("Line \(index).\n"))
        }
        #expect(try harness.git("rev-list", "--count", "HEAD..fen/claude") == "6\n")
    }

    @Test func twoAgentsCreatingTheSameNewFileGetAClearSignal() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        try await harness.gate.submitRouted(
            harness.proposal(.createFile(path: "new.md", content: "Claude's\n"), as: "Claude", base: .some(nil))
        )
        do {
            try await harness.gate.submitRouted(
                harness.proposal(.createFile(path: "new.md", content: "Codex's\n"), as: "Codex", base: .some(nil))
            )
            Issue.record("The second create should be refused")
        } catch let AgentBranchError.claimed(path, owner, _) {
            #expect(path == "new.md")
            #expect(owner == "Claude")
        }
        #expect(try harness.git("branch", "--list", "fen/codex").isEmpty)
        // A different name is free.
        try await harness.gate.submitRouted(
            harness.proposal(.createFile(path: "new-2.md", content: "Codex's\n"), as: "Codex", base: .some(nil))
        )
    }

    @Test func editingAnExistingFileTakesNoClaim() async throws {
        let harness = try GateHarness.agents()
        defer { harness.cleanUp() }
        try await harness.gate.submitRouted(harness.proposal(.append(path: "a.md", text: "x\n"), as: "Claude"))
        try await harness.gate.submitRouted(harness.proposal(.append(path: "a.md", text: "y\n"), as: "Codex"))
        let refs = try harness.git("for-each-ref", "refs/fen/claims/")
        #expect(refs.isEmpty)
    }
}
