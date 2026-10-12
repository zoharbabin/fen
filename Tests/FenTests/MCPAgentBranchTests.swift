@testable import FenCore
import Foundation
import Testing

@MainActor
@Suite("MCP: agents write to their own branches (issue #93)")
struct MCPAgentBranchTests {
    private func allowAuto(_ fixture: MCPFixture, _ clients: [String]) throws {
        try fixture.library.updateSettings(id: fixture.notesID) { settings in
            settings.writePolicy.autoApproveConfirmed = true
            settings.writePolicy.maxFilesPerRun = 1000
            settings.writePolicy.overrides = clients.map {
                .init(kind: .client, match: $0, mode: .autoApprove, confirmed: true)
            }
        }
    }

    private func edit(_ op: String, _ path: String, _ text: String) -> [String: Any] {
        op == "createFile"
            ? ["op": op, "path": path, "content": text]
            : ["op": op, "path": path, "text": text]
    }

    private func git(_ fixture: MCPFixture, _ arguments: String...) throws -> String {
        try fixture.notes.git(arguments)
    }

    @Test func getDocumentNamesTheBranchAndProposeEditCommitsToIt() async throws {
        let fixture = try await MCPFixture(git: true)
        defer { fixture.cleanUp() }
        try allowAuto(fixture, ["Claude"])
        let token = try fixture.addClient("Claude", level: .readAndPropose)

        let read = await fixture.tool("get_document", ["path": "ideas.md"], token: token)
        #expect(read.data["branch"] as? String == "fen/claude")
        let hash = try #require(read.data["contentHash"] as? String)

        let done = await fixture.tool(
            "propose_edit",
            ["edit": edit("append", "ideas.md", "More.\n"), "baseHash": hash],
            token: token
        )
        #expect(!done.isError)
        #expect(done.data["status"] as? String == "applied")
        #expect(done.data["branch"] as? String == "fen/claude")
        #expect((done.data["commit"] as? String)?.count == 40)
        #expect(try fixture.text("ideas.md") == MCPFixture.notesFiles["ideas.md"])
        #expect(try git(fixture, "show", "fen/claude:ideas.md").hasSuffix("More.\n"))
        #expect(
            try git(fixture, "branch", "--show-current") == "master\n" || git(fixture, "branch", "--show-current") ==
                "main\n"
        )
    }

    @Test func aTrackedFileAnExcludeGlobHidesIsNotReadFromTheBranch() async throws {
        let fixture = try await MCPFixture(git: true)
        defer { fixture.cleanUp() }
        try fixture.library.updateSettings(id: fixture.notesID) { $0.excludeGlobs = ["meetings/**"] }
        let token = try fixture.addClient("Claude", level: .readAndPropose)
        let read = await fixture.tool("get_document", ["path": "meetings/retro.md"], token: token)
        #expect(read.isError)
        #expect(read.data["text"] == nil)
    }

    @Test func aReadOnlyClientReadsYourFilesNotABranch() async throws {
        let fixture = try await MCPFixture(git: true)
        defer { fixture.cleanUp() }
        let token = try fixture.addClient("Reader", level: .read)
        let read = await fixture.tool("get_document", ["path": "ideas.md"], token: token)
        #expect(read.data["branch"] == nil)
        #expect(read.data["text"] as? String == MCPFixture.notesFiles["ideas.md"])
    }

    @Test func aStaleHashGivesARetrySignal() async throws {
        let fixture = try await MCPFixture(git: true)
        defer { fixture.cleanUp() }
        try allowAuto(fixture, ["Claude"])
        let token = try fixture.addClient("Claude", level: .readAndPropose)
        let hash = try #require(await fixture.tool("get_document", ["path": "ideas.md"], token: token)
            .data["contentHash"] as? String)
        _ = await fixture.tool(
            "propose_edit",
            ["edit": edit("append", "ideas.md", "1\n"), "baseHash": hash],
            token: token
        )

        let stale = await fixture.tool(
            "propose_edit",
            ["edit": edit("append", "ideas.md", "2\n"), "baseHash": hash],
            token: token
        )
        #expect(stale.isError)
        #expect(stale.data["retry"] as? Bool == true)
        #expect((stale.data["error"] as? String)?.contains("get_document") == true)
    }

    @Test func aClaimedNewFileSaysWhoHoldsIt() async throws {
        let fixture = try await MCPFixture(git: true)
        defer { fixture.cleanUp() }
        try allowAuto(fixture, ["Claude", "Codex"])
        let claude = try fixture.addClient("Claude", level: .readAndPropose)
        let codex = try fixture.addClient("Codex", level: .readAndPropose)
        let first = await fixture.tool("propose_edit", ["edit": edit("createFile", "plan.md", "A\n")], token: claude)
        #expect(first.data["status"] as? String == "applied")
        let second = await fixture.tool("propose_edit", ["edit": edit("createFile", "plan.md", "B\n")], token: codex)
        #expect(second.isError)
        #expect((second.data["error"] as? String)?.contains("Claude") == true)
        #expect(second.data["retry"] == nil)
    }

    @Test func aWorkspaceWithoutGitKeepsTheApprovalFlow() async throws {
        let fixture = try await MCPFixture()
        defer { fixture.cleanUp() }
        let token = try fixture.addClient("Claude", level: .readAndPropose)
        let read = await fixture.tool("get_document", ["path": "ideas.md"], token: token)
        #expect(read.data["branch"] == nil)
        let hash = try #require(read.data["contentHash"] as? String)
        let done = await fixture.tool(
            "propose_edit",
            ["edit": edit("append", "ideas.md", "More.\n"), "baseHash": hash],
            token: token
        )
        #expect(done.data["status"] as? String == "waiting_for_approval")
        #expect(try fixture.text("ideas.md") == MCPFixture.notesFiles["ideas.md"])
    }

    // MARK: - Load

    /// Several agents work at once. Each appends to one shared note and creates its own notes.
    /// Nothing is lost, nothing in the checkout changes, and the repository stays sound.
    @Test func manyAgentsWritingAtOnceLoseNothing() async throws {
        let agents = 8, appends = 3, creates = 2
        let fixture = try await MCPFixture(git: true)
        defer { fixture.cleanUp() }
        let names = (0 ..< agents).map { "agent\($0)" }
        try allowAuto(fixture, names)
        var tokens: [String: String] = [:]
        for name in names {
            tokens[name] = try fixture.addClient(name, level: .readAndPropose)
        }
        let before = try git(fixture, "rev-parse", "HEAD")
        let started = ContinuousClock.now

        var workers: [Task<Int, Never>] = []
        for name in names {
            let token = try #require(tokens[name])
            workers.append(Task {
                var retries = 0
                for index in 0 ..< appends {
                    var landed = false
                    for _ in 0 ..< 10 where !landed {
                        let read = await fixture.tool("get_document", ["path": "ideas.md"], token: token)
                        let hash = read.data["contentHash"] as? String ?? ""
                        let line = "\(name) line \(index)\n"
                        let result = await fixture.tool(
                            "propose_edit",
                            ["edit": edit("append", "ideas.md", line), "baseHash": hash],
                            token: token
                        )
                        landed = result.data["status"] as? String == "applied"
                        retries += landed ? 0 : 1
                    }
                }
                for index in 0 ..< creates {
                    let result = await fixture.tool(
                        "propose_edit",
                        ["edit": edit("createFile", "\(name)-\(index).md", "# \(name) \(index)\n")],
                        token: token
                    )
                    #expect(result.data["status"] as? String == "applied", "\(name) create \(index)")
                }
                return retries
            })
        }
        var retries = 0
        for worker in workers {
            retries += await worker.value
        }
        let elapsed = ContinuousClock.now - started
        print("Load test: \(agents) agents, \(agents * (appends + creates)) commits, \(retries) retries, \(elapsed)")

        for name in names {
            let branch = "fen/\(name)"
            let ideas = try git(fixture, "show", "\(branch):ideas.md")
            for index in 0 ..< appends {
                #expect(ideas.contains("\(name) line \(index)\n"), "\(name) lost line \(index)")
            }
            let files = try git(fixture, "ls-tree", "--name-only", branch)
            for index in 0 ..< creates {
                #expect(files.contains("\(name)-\(index).md"), "\(name) lost note \(index)")
            }
            #expect(try git(fixture, "rev-list", "--count", "HEAD..\(branch)") == "\(appends + creates)\n")
        }
        #expect(try git(fixture, "rev-parse", "HEAD") == before)
        #expect(try git(fixture, "status", "--porcelain").contains("ideas.md") == false)
        #expect(try fixture.text("ideas.md") == MCPFixture.notesFiles["ideas.md"])
        #expect(try git(fixture, "fsck", "--strict", "--no-dangling").contains("error") == false)
        #expect(fixture.gate.entries(for: fixture.notesID).count == agents * (appends + creates))
        #expect(elapsed < .seconds(120))
    }
}
