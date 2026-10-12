@testable import FenCore
import Foundation
import Testing

@MainActor
struct PushAsPRTests {
    private func reviewMode(_ setup: SyncModeSetup) {
        setup.knobs.mode = .pushAsPR
    }

    @Test func eachSetOfChangesGoesToABranchWithOnePullRequest() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()

        #expect(model.message == nil)
        let branches = try setup.remoteReviewBranches()
        #expect(branches.count == 1)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A")
        #expect(try setup.remoteGit("show", "\(branches[0]):a.md") == "# A2")
        #expect(setup.api.opened.count == 1)
        #expect(setup.api.opened.first?.head == branches[0])
        #expect(setup.api.opened.first?.base == "main")
        #expect(setup.api.opened.first?.title == "Update a.md")
        #expect(model.pullRequest?.number == 1)
        #expect(try setup.git("branch", "--show-current") == branches[0])
        #expect(try setup.git("status", "--porcelain").isEmpty)
    }

    @Test func moreChangesJoinTheOpenPullRequest() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        try setup.edit("notes/b.md", "# B2\n")
        await model.syncNow()

        let branch = try #require(setup.remoteReviewBranches().first)
        #expect(try setup.remoteReviewBranches().count == 1)
        #expect(setup.api.opened.count == 1)
        #expect(try setup.remoteGit("show", "\(branch):notes/b.md") == "# B2")
        #expect(try setup.remoteGit("rev-list", "--count", "main..\(branch)") == "2")
    }

    @Test func nothingChangedOpensNothing() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(try setup.remoteReviewBranches().isEmpty)
        #expect(setup.api.opened.isEmpty)
        #expect(try setup.git("branch", "--show-current") == "main")
    }

    @Test func aiChangesGoInTheReviewBranchBecauseAPersonLooksAtThem() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.edit("a.md", "# A, changed by AI\n")
        setup.knobs.aiChanges = ["a.md": Date().addingTimeInterval(5)]
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let branch = try #require(setup.remoteReviewBranches().first)
        #expect(try setup.remoteGit("show", "\(branch):a.md") == "# A, changed by AI")
        #expect(try setup.remoteGit("show", "main:a.md") == "# A")
    }

    @Test func afterTheMergeTheFolderGoesBackToTheDefaultBranch() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let branch = try #require(setup.remoteReviewBranches().first)
        // The reviewer merges on GitHub.
        try setup.remoteGit("update-ref", "refs/heads/main", branch)
        setup.api.finish(branch, as: .merged)

        await model.syncNow()
        #expect(model.message == nil)
        #expect(try setup.git("branch", "--show-current") == "main")
        #expect(try setup.git("show", "main:a.md") == "# A2")
        #expect(model.pullRequest == nil)
        #expect(setup.api.opened.count == 1)
    }

    @Test func editsAfterAMergeStartANewPullRequest() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let first = try #require(setup.remoteReviewBranches().first)
        try setup.remoteGit("update-ref", "refs/heads/main", first)
        setup.api.finish(first, as: .merged)

        try setup.edit("notes/b.md", "# B3\n")
        // The next branch name uses the clock in whole seconds, so wait for a new one.
        let second = try await pollUntilTrue(timeout: .seconds(5)) {
            GitSync.workingBranchName() != first
        }
        try #require(second)
        await model.syncNow()

        #expect(setup.api.opened.count == 2)
        let branches = try setup.remoteReviewBranches()
        #expect(branches.count == 2)
        let newer = try #require(branches.first { $0 != first })
        #expect(try setup.remoteGit("show", "\(newer):notes/b.md") == "# B3")
        #expect(try setup.remoteGit("show", "main:notes/b.md") == "# B")
    }

    @Test func commitsNotYetPushedMoveToTheBranchAndStayReachable() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        // These commits were made in back-up mode and never pushed.
        try setup.edit("a.md", "# A, saved here\n")
        try await setup.fixture.sync.commitChanges(at: setup.mine)
        let saved = try setup.git("rev-parse", "HEAD")
        reviewMode(setup)
        let model = setup.model()
        await model.open()
        await model.syncNow()

        let branch = try #require(setup.remoteReviewBranches().first)
        #expect(try setup.remoteGit("rev-parse", branch) == saved)
        #expect(try setup.git("rev-parse", "main") == setup.remoteGit("rev-parse", "main"))
        #expect(try setup.git("merge-base", "--is-ancestor", saved, branch).isEmpty)
        #expect(setup.api.opened.count == 1)
    }

    @Test func onlySecretLookingFilesChangedLeavesNoBranchBehind() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.edit(".env", "TOKEN=1\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(model.message?.contains("secrets") == true)
        #expect(try setup.git("branch", "--show-current") == "main")
        #expect(try setup.git("branch", "--list", "fen/*").isEmpty)
        #expect(setup.api.opened.isEmpty)
    }

    @Test func withoutATokenItAsksForOneAndChangesNothing() async throws {
        let setup = try await SyncModeSetup(token: false)
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(model.needsToken)
        #expect(try setup.git("branch", "--show-current") == "main")
        #expect(try setup.git("status", "--porcelain") == "M a.md")
    }

    @Test func aBranchOfYoursIsLeftAlone() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.git("switch", "-q", "-c", "mine")
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        #expect(model.message?.contains("mine") == true)
        #expect(try setup.git("branch", "--show-current") == "mine")
        #expect(setup.api.opened.isEmpty)
    }

    @Test func theHeaderNamesTheBranchAndThePullRequest() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        reviewMode(setup)
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let text = SyncSummary.text(
            mode: .pushAsPR,
            status: model.status,
            pullRequest: model.pullRequest,
            held: 0,
            repo: "o/n"
        )
        #expect(text.contains("fen/changes-"))
        #expect(text.hasSuffix("PR #1 open"))
    }
}

@MainActor
struct SwitchingSyncModeTests {
    @Test func backUpLeavesAnOpenPullRequestAndYourEditsAlone() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        setup.knobs.mode = .pushAsPR
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let branch = try #require(setup.remoteReviewBranches().first)
        let tip = try setup.remoteGit("rev-parse", branch)

        setup.knobs.mode = .directCommit
        try setup.edit("notes/b.md", "# B edited after the switch\n")
        await model.syncNow()

        #expect(model.message?.contains("pull request #1") == true)
        #expect(try setup.remoteGit("rev-parse", "main") == setup.git("rev-parse", "main"))
        #expect(try setup.remoteGit("rev-parse", branch) == tip)
        #expect(try setup.git("status", "--porcelain") == "M notes/b.md")
        #expect(try setup.git("branch", "--show-current") == branch)
    }

    @Test func backUpReturnsToTheDefaultBranchOnceThePullRequestIsDone() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        setup.knobs.mode = .pushAsPR
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let branch = try #require(setup.remoteReviewBranches().first)
        try setup.remoteGit("update-ref", "refs/heads/main", branch)
        setup.api.finish(branch, as: .merged)

        setup.knobs.mode = .directCommit
        try setup.edit("notes/b.md", "# B after the merge\n")
        await model.syncNow()

        #expect(model.message == nil)
        #expect(try setup.git("branch", "--show-current") == "main")
        #expect(try setup.remoteGit("show", "main:notes/b.md") == "# B after the merge")
        #expect(try setup.remoteGit("show", "main:a.md") == "# A2")
    }

    @Test func backUpDoesNotLeaveAFinishedBranchThatHasEdits() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        setup.knobs.mode = .pushAsPR
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let branch = try #require(setup.remoteReviewBranches().first)
        setup.api.finish(branch, as: .closed)

        setup.knobs.mode = .directCommit
        try setup.edit("a.md", "# A3\n")
        await model.syncNow()
        #expect(model.message?.contains("edits") == true)
        #expect(try setup.git("branch", "--show-current") == branch)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A")
        #expect(try setup.git("status", "--porcelain") == "M a.md")
    }

    @Test func pullRequestsAfterBackUpStartFromTheCommitsYouKept() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let model = setup.model()
        await model.open()
        try setup.edit("a.md", "# A backed up\n")
        await model.syncNow()
        setup.knobs.mode = .pushAsPR
        try setup.edit("notes/b.md", "# B for review\n")
        await model.syncNow()
        let branch = try #require(setup.remoteReviewBranches().first)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A backed up")
        #expect(try setup.remoteGit("show", "main:notes/b.md") == "# B")
        #expect(try setup.remoteGit("show", "\(branch):notes/b.md") == "# B for review")
        #expect(try setup.remoteGit("rev-list", "--count", "main..\(branch)") == "1")
    }
}

@MainActor
struct DefaultBranchTests {
    @Test func itReadsOriginHead() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        #expect(try await setup.fixture.sync.defaultBranch(at: setup.mine) == "main")
    }

    @Test func itAsksTheRemoteWhenOriginHeadIsMissing() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        try setup.git("remote", "set-head", "origin", "--delete")
        #expect(try await setup.fixture.sync.defaultBranch(at: setup.mine) == "main")
    }

    @Test func branchNamesUseUTCAndTheFenPrefix() {
        let name = GitSync.workingBranchName(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(name == "fen/changes-20231114-221320")
        #expect(GitSync.isWorkingBranch(name))
        #expect(!GitSync.isWorkingBranch("fen/claude"))
        #expect(!GitSync.isWorkingBranch(nil))
    }
}

@MainActor
struct BackUpOnSaveTests {
    @Test func aDirectCommitWorkspaceBacksUpWhenChangesStop() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let model = setup.model(saveDelay: .milliseconds(50))
        await model.open()
        try setup.edit("a.md", "# A saved\n")
        model.noteChanged()
        let backedUp = try await pollUntilTrue(timeout: .seconds(20)) {
            (try? setup.remoteGit("show", "main:a.md")) == "# A saved"
        }
        #expect(backedUp)
    }

    @Test func aPullRequestWorkspaceDoesNotBackUpOnSave() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        setup.knobs.mode = .pushAsPR
        let model = setup.model(saveDelay: .milliseconds(10))
        await model.open()
        try setup.edit("a.md", "# A saved\n")
        model.noteChanged()
        #expect(model.autoTask == nil)
    }

    @Test func aWorkspaceWithoutAChosenModeDoesNotBackUpOnSave() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        setup.knobs.mode = nil
        let model = setup.model(saveDelay: .milliseconds(10))
        await model.open()
        model.noteChanged()
        #expect(model.autoTask == nil)
    }

    @Test func aBackUpWithNothingChangedTouchesNoRemote() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let model = setup.model(saveDelay: .milliseconds(10))
        await model.open()
        let head = try setup.remoteGit("rev-parse", "main")
        model.noteChanged()
        let task = try #require(model.autoTask)
        await task.value
        #expect(model.working == nil)
        #expect(try setup.remoteGit("rev-parse", "main") == head)
    }

    @Test func newChangesPostponeTheBackUp() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let model = setup.model(saveDelay: .seconds(60))
        await model.open()
        try setup.edit("a.md", "# A saved\n")
        model.noteChanged()
        let first = try #require(model.autoTask)
        model.noteChanged()
        let second = try #require(model.autoTask)
        // The first wait was canceled, and a later change starts a new one.
        _ = try await pollUntilTrue { first.isCancelled }
        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        second.cancel()
        #expect(try setup.remoteGit("show", "main:a.md") == "# A")
    }
}
