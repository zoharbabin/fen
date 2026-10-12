@testable import FenCore
import Foundation
import Testing

@Suite("Agent branches: git plumbing")
struct AgentBranchesTests {
    @Test func aFolderOutsideARepositoryHasNoBranch() async throws {
        let folder = try TempFolder("not-git")
        defer { folder.cleanUp() }
        #expect(await AgentBranches(git: GitFixture.tool).open(directory: folder.root, client: "Claude") == nil)
    }

    @Test func aRepositoryWithoutACommitHasNoBranch() async throws {
        let folder = try TempFolder("empty-git")
        defer { folder.cleanUp() }
        try folder.git("init", "-q")
        #expect(await AgentBranches(git: GitFixture.tool).open(directory: folder.root, client: "Claude") == nil)
    }

    @Test func withoutGitNothingOpens() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let none = AgentBranches(git: nil)
        #expect(!none.isAvailable)
        #expect(await none.open(directory: fixture.root, client: "Claude") == nil)
    }

    @Test func branchNamesAreSafeAndStable() {
        #expect(AgentBranches.branchName(for: "claude") == "fen/claude")
        let spaced = AgentBranches.branchName(for: "Claude Code")
        #expect(spaced.hasPrefix("fen/claude-code-"))
        #expect(spaced == AgentBranches.branchName(for: "Claude Code"))
        #expect(spaced != AgentBranches.branchName(for: "claude-code"))
        #expect(AgentBranches.branchName(for: "../../x").hasPrefix("fen/x-"))
        #expect(!AgentBranches.branchName(for: "../../x").contains(".."))
        #expect(AgentBranches.branchName(for: "日本語").hasPrefix("fen/agent-"))
        #expect(AgentBranches.branchName(for: String(repeating: "a", count: 200)).count < 60)
    }

    // MARK: - Committing

    @Test func aCommitLandsOnTheBranchAndLeavesYourCheckoutAlone() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let headBefore = try fixture.git("rev-parse", "HEAD")
        let indexBefore = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
        try fixture.folder.write("a.md", "# Mine, unsaved to git\n")

        try await fixture.commit("a.md", "# From the agent\n", as: "Claude")

        #expect(try fixture.git("show", "fen/claude:a.md") == "# From the agent\n")
        #expect(try fixture.git("rev-parse", "HEAD") == headBefore)
        #expect(try fixture.git("rev-parse", "--abbrev-ref", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "main")
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")) == indexBefore)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("a.md"), encoding: .utf8)
            == "# Mine, unsaved to git\n")
        #expect(try fixture.git("fsck", "--strict").contains("error") == false)
    }

    @Test func aCommitCarriesTheAgentAndTrailers() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let branch = try await fixture.branch("Claude Code")
        _ = try await fixture.branches.commit(
            [AgentFileChange(path: "a.md", data: Data("x\n".utf8), mode: nil)],
            message: AgentCommitMessage(
                subject: "Edit a.md",
                trailers: [("Fen-Agent", "Claude Code"), ("Fen-Run", "r1")]
            ),
            on: branch,
            expectedTip: nil
        )
        let log = try fixture.git("log", "-1", "--format=%an|%ae|%cn|%s%n%b", branch.name)
        #expect(log.contains("Claude Code|agent@fen.invalid|Fen|Edit a.md"))
        #expect(log.contains("Fen-Agent: Claude Code"))
        #expect(log.contains("Fen-Run: r1"))
        #expect(try fixture.git("log", "-1", "--format=%P", branch.name).trimmingCharacters(in: .whitespacesAndNewlines)
            == fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func aStaleTipIsRefusedAndNothingMoves() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let branch = try await fixture.branch("Claude")
        let first = try await fixture.commit("a.md", "one\n", as: "Claude")
        let change = [AgentFileChange(path: "a.md", data: Data("two\n".utf8), mode: nil)]
        let message = AgentCommitMessage(subject: "x", trailers: [])

        // Two writers both read the tip `first`. The first to finish wins.
        _ = try await fixture.branches.commit(change, message: message, on: branch, expectedTip: first)
        let tipAfter = try await fixture.branches.tip(of: branch)
        await #expect(throws: AgentBranchError.branchMoved("fen/claude")) {
            _ = try await fixture.branches.commit(
                [AgentFileChange(path: "a.md", data: Data("three\n".utf8), mode: nil)],
                message: message,
                on: branch,
                expectedTip: first
            )
        }
        #expect(try await fixture.branches.tip(of: branch) == tipAfter)
        #expect(try fixture.git("show", "fen/claude:a.md") == "two\n")
    }

    @Test func aNewBranchRefusesToReplaceOneThatAppearedMeanwhile() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let branch = try await fixture.branch("Claude")
        try await fixture.commit("a.md", "one\n", as: "Claude")
        await #expect(throws: AgentBranchError.branchMoved("fen/claude")) {
            _ = try await fixture.branches.commit(
                [AgentFileChange(path: "a.md", data: Data("x\n".utf8), mode: nil)],
                message: AgentCommitMessage(subject: "x", trailers: []),
                on: branch,
                expectedTip: nil
            )
        }
    }

    @Test func deleteAndCreateAndExecutableBitSurvive() async throws {
        let fixture = try GitFixture(["run.md": "#!x\n", "gone.md": "bye\n"])
        defer { fixture.cleanUp() }
        try fixture.git("update-index", "--chmod=+x", "run.md")
        try fixture.git("commit", "-q", "-m", "exec")
        let branch = try await fixture.branch("Claude")
        let file = try #require(await fixture.branches.read("run.md", on: branch))
        #expect(file.mode == "100755")
        _ = try await fixture.branches.commit(
            [
                AgentFileChange(path: "run.md", data: Data("#!y\n".utf8), mode: file.mode),
                AgentFileChange(path: "gone.md", data: nil, mode: nil),
                AgentFileChange(path: "new/deep.md", data: Data("n\n".utf8), mode: nil),
            ],
            message: AgentCommitMessage(subject: "x", trailers: []),
            on: branch,
            expectedTip: nil
        )
        #expect(try fixture.git("ls-tree", "fen/claude", "run.md").hasPrefix("100755"))
        #expect(try fixture.git("ls-tree", "-r", "--name-only", "fen/claude").contains("gone.md") == false)
        #expect(try fixture.git("show", "fen/claude:new/deep.md") == "n\n")
    }

    @Test func aPathWithANewlineOrQuoteCannotAddASecondIndexEntry() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let branch = try await fixture.branch("Claude")
        let zero = String(repeating: "0", count: 40)
        let smuggled = "x.md\n0 \(zero)\ta.md"
        _ = try await fixture.branches.commit(
            [
                AgentFileChange(path: smuggled, data: Data("x\n".utf8), mode: nil),
                AgentFileChange(path: "\"q.md\"", data: Data("q\n".utf8), mode: nil),
            ],
            message: AgentCommitMessage(subject: "x", trailers: []),
            on: branch,
            expectedTip: nil
        )
        let names = try fixture.git("ls-tree", "-r", "-z", "--name-only", "fen/claude")
            .split(separator: "\0").map(String.init)
        #expect(names.contains("a.md"))
        #expect(names.contains(smuggled))
        #expect(names.contains("\"q.md\""))
        #expect(!names.contains("q.md"))
    }

    @Test func aWorkspaceBelowTheRepositoryRootCommitsUnderItsFolder() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let sub = fixture.root.appendingPathComponent("notes")
        let branch = try await fixture.branch("Claude", in: sub)
        #expect(branch.prefix == "notes/")
        try await fixture.commit("b.md", "# B2\n", as: "Claude", in: sub)
        #expect(try fixture.git("show", "fen/claude:notes/b.md") == "# B2\n")
        #expect(try fixture.git("show", "fen/claude:a.md") == "# A\n")
        let read = try #require(await fixture.branches.read("b.md", on: branch))
        #expect(String(decoding: read.data, as: UTF8.self) == "# B2\n")
    }

    // MARK: - Reading

    @Test func readsHeadUntilTheBranchChangesTheFile() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let branch = try await fixture.branch("Claude")
        var file = try #require(await fixture.branches.read("a.md", on: branch))
        #expect(file.changedOnBranch == false)
        #expect(String(decoding: file.data, as: UTF8.self) == "# A\n")

        try await fixture.commit("a.md", "# Agent\n", as: "Claude")
        file = try #require(await fixture.branches.read("a.md", on: branch))
        #expect(file.changedOnBranch)
        #expect(String(decoding: file.data, as: UTF8.self) == "# Agent\n")

        // You commit another file on main. The agent sees it, and still sees its own change.
        try fixture.folder.write("notes/b.md", "# B by you\n")
        try fixture.git("commit", "-q", "-am", "yours")
        let other = try #require(await fixture.branches.read("notes/b.md", on: branch))
        #expect(String(decoding: other.data, as: UTF8.self) == "# B by you\n")
        #expect(other.changedOnBranch == false)
        let mine = try #require(await fixture.branches.read("a.md", on: branch))
        #expect(String(decoding: mine.data, as: UTF8.self) == "# Agent\n")
    }

    @Test func aFileGitDoesNotTrackIsNotOnTheBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        try fixture.folder.write("draft.md", "untracked\n")
        let branch = try await fixture.branch("Claude")
        #expect(try await fixture.branches.read("draft.md", on: branch) == nil)
        #expect(try await fixture.branches.read("missing.md", on: branch) == nil)
    }

    @Test func aPathThatLooksLikeAnOptionOrPathspecIsTakenLiterally() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let branch = try await fixture.branch("Claude")
        #expect(try await fixture.branches.read("--help", on: branch) == nil)
        #expect(try await fixture.branches.read("*.md", on: branch) == nil)
        #expect(try await fixture.branches.read(":(top)a.md", on: branch) == nil)
    }

    // MARK: - Merging

    @Test func aMergedBranchMovesForwardToHead() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let branch = try await fixture.branch("Claude")
        try await fixture.commit("a.md", "# Agent\n", as: "Claude")
        try fixture.git("merge", "-q", "--no-edit", "fen/claude")
        try fixture.folder.write("notes/b.md", "# Later\n")
        try fixture.git("commit", "-q", "-am", "later")
        try await fixture.branches.fastForwardIfMerged(branch)
        #expect(try fixture.git("rev-parse", "fen/claude") == fixture.git("rev-parse", "HEAD"))
    }

    @Test func anUnmergedBranchStaysWhereItIs() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let branch = try await fixture.branch("Claude")
        let tip = try await fixture.commit("a.md", "# Agent\n", as: "Claude")
        try fixture.folder.write("notes/b.md", "# Later\n")
        try fixture.git("commit", "-q", "-am", "later")
        try await fixture.branches.fastForwardIfMerged(branch)
        #expect(try await fixture.branches.tip(of: branch) == tip)
    }

    @Test func summariesCountCommitsNotYetInHead() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        try await fixture.commit("a.md", "1\n", as: "Claude")
        try await fixture.commit("a.md", "2\n", as: "Claude")
        try await fixture.commit("notes/b.md", "1\n", as: "Other")
        let summaries = await fixture.branches.summaries(in: fixture.root)
        #expect(summaries.contains(AgentBranches.Summary(name: "fen/claude", ahead: 2)))
        #expect(summaries.contains(AgentBranches.Summary(name: "fen/other", ahead: 1)))
    }

    // MARK: - Claims

    @Test func aClaimStopsAnotherAgentUntilItExpires() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let alice = try await fixture.branch("alice"), bob = try await fixture.branch("bob")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.branches.claim("new.md", for: alice, now: t0)

        await #expect(throws: AgentBranchError.claimed(
            path: "new.md",
            by: "alice",
            until: t0.addingTimeInterval(AgentBranches.claimLifetime)
        )) {
            try await fixture.branches.claim("new.md", for: bob, now: t0.addingTimeInterval(60))
        }
        // The owner can renew. After the lifetime, someone else can take it.
        try await fixture.branches.claim("new.md", for: alice, now: t0.addingTimeInterval(120))
        try await fixture.branches.claim(
            "new.md",
            for: bob,
            now: t0.addingTimeInterval(120 + AgentBranches.claimLifetime + 1)
        )
        let held = try await fixture.branches.claims(in: bob, now: t0.addingTimeInterval(700))
        #expect(held.map(\.client) == ["bob"])
    }

    @Test func onlyTheOwnerReleasesAClaim() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let alice = try await fixture.branch("alice"), bob = try await fixture.branch("bob")
        try await fixture.branches.claim("new.md", for: alice)
        try await fixture.branches.release("new.md", for: bob)
        #expect(try await fixture.branches.claims(in: alice).count == 1)
        try await fixture.branches.release("new.md", for: alice)
        #expect(try await fixture.branches.claims(in: alice).isEmpty)
        try await fixture.branches.claim("new.md", for: bob)
    }

    @Test func claimsAreKeyedByPathSoOtherPathsStayFree() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let alice = try await fixture.branch("alice"), bob = try await fixture.branch("bob")
        try await fixture.branches.claim("one.md", for: alice)
        try await fixture.branches.claim("two.md", for: bob)
        #expect(try await fixture.branches.claims(in: alice).map(\.path) == ["one.md", "two.md"])
    }

    @Test func manyAgentsRacingForOnePathGiveExactlyOneWinner() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        var branches: [AgentBranch] = []
        for index in 0 ..< 8 {
            try await branches.append(fixture.branch("agent\(index)"))
        }
        let wins = await withTaskGroup(of: Bool.self) { group in
            for branch in branches {
                group.addTask {
                    await (try? fixture.branches.claim("race.md", for: branch)) != nil
                }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        #expect(wins == 1)
    }
}
