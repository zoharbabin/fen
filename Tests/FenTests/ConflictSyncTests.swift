@testable import FenCore
import Foundation
import Testing

/// One person editing a note on two devices (issue #62). Git is the second device: another clone of
/// the same remote.
@MainActor
struct DirectConflictTests {
    /// `mine` and `other` both changed `a.md`. `other` already pushed.
    private func conflicting(_ setup: SyncModeSetup) async throws -> URL {
        let other = try await setup.fixture.clone("other")
        try setup.fixture.publish("a.md", "# A\nfrom the phone\n", from: other)
        try setup.edit("a.md", "# A\nfrom the laptop\n")
        return other
    }

    @Test func bothVersionsStayInTheNoteAndNothingIsPushed() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        _ = try await conflicting(setup)
        let before = try setup.remoteGit("rev-parse", "main")
        let model = setup.model()
        await model.open()
        await model.syncNow()

        let text = try String(contentsOf: setup.mine.appendingPathComponent("a.md"), encoding: .utf8)
        #expect(text.contains("from the laptop"))
        #expect(text.contains("from the phone"))
        #expect(text.contains("<<<<<<< "))
        #expect(text.contains(">>>>>>> "))
        #expect(model.conflicts == ["a.md"])
        #expect(model.message?.contains("1 note has conflicts: a.md") == true)
        #expect(try setup.remoteGit("rev-parse", "main") == before)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A\nfrom the phone")
    }

    @Test func nothingWithMarkersIsPushedUntilTheyAreGone() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        _ = try await conflicting(setup)
        let before = try setup.remoteGit("rev-parse", "main")
        let model = setup.model()
        await model.syncNow()
        // Syncing again, or editing only the text around the markers, still leaves GitHub alone.
        await model.syncNow()
        #expect(model.conflicts == ["a.md"])
        let text = try String(contentsOf: setup.mine.appendingPathComponent("a.md"), encoding: .utf8)
        try setup.edit("a.md", "intro\n" + text)
        await model.syncNow()
        #expect(model.conflicts == ["a.md"])
        #expect(try setup.remoteGit("rev-parse", "main") == before)
    }

    @Test func editingTheMarkersAwayFinishesTheMergeAndKeepsBothInHistory() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let other = try await conflicting(setup)
        let model = setup.model()
        await model.syncNow()
        try setup.edit("a.md", "# A\nfrom the phone and the laptop\n")
        await model.syncNow()

        #expect(model.conflicts.isEmpty)
        #expect(model.message == nil)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A\nfrom the phone and the laptop")
        // Both devices' versions are parents of the result.
        #expect(try setup.remoteGit("show", "main^1:a.md") == "# A\nfrom the laptop")
        #expect(try setup.remoteGit("show", "main^2:a.md") == "# A\nfrom the phone")
        #expect(try setup.git("status", "--porcelain").isEmpty)
        // The other device gets the result.
        try setup.fixture.git(other, "pull", "-q", "--ff-only")
        let theirs = try String(contentsOf: other.appendingPathComponent("a.md"), encoding: .utf8)
        #expect(theirs == "# A\nfrom the phone and the laptop\n")
    }

    @Test func notesTheOtherDeviceDidNotTouchMergeWithoutAsking() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let other = try await setup.fixture.clone("other")
        try setup.fixture.publish("notes/b.md", "# B2\n", from: other)
        try setup.edit("a.md", "# A2\n")
        try setup.git("add", "-A")
        try setup.git("commit", "-q", "-m", "local")
        let model = setup.model()
        await model.syncNow()

        #expect(model.message == nil)
        #expect(model.conflicts.isEmpty)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A2")
        #expect(try setup.remoteGit("show", "main:notes/b.md") == "# B2")
    }

    @Test func aNoteYouEditedWhileGitHubChangedADifferentOneNeedsNoMerge() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let other = try await setup.fixture.clone("other")
        try setup.fixture.publish("notes/b.md", "# B2\n", from: other)
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.syncNow()
        #expect(model.message == nil)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A2")
        #expect(try setup.remoteGit("show", "main:notes/b.md") == "# B2")
        #expect(try setup.remoteGit("rev-list", "--merges", "--count", "main") == "0")
    }

    @Test func aFileThatCannotHoldMarkersKeepsYoursAndSavesTheOtherAsACopy() async throws {
        let fixture = try SyncFixture(files: ["a.md": "# A\n", "img.png": "x"])
        let setup = try await SyncModeSetup(fixture: fixture)
        defer { setup.cleanUp() }
        let other = try await fixture.clone("other")
        let phone = Data([0, 1, 2, 3])
        let laptop = Data([0, 9, 9, 9])
        try phone.write(to: other.appendingPathComponent("img.png"))
        try fixture.git(other, "add", "-A")
        try fixture.git(other, "commit", "-q", "-m", "phone")
        try fixture.git(other, "push", "-q", "origin", "main")
        try laptop.write(to: setup.mine.appendingPathComponent("img.png"))
        let model = setup.model()
        await model.syncNow()

        #expect(model.conflicts.isEmpty)
        #expect(try Data(contentsOf: setup.mine.appendingPathComponent("img.png")) == laptop)
        #expect(try Data(contentsOf: setup.mine.appendingPathComponent("img (GitHub copy).png")) == phone)
        #expect(model.message?.contains("img (GitHub copy).png") == true)
        #expect(try setup.remoteGit("ls-tree", "--name-only", "main").contains("img (GitHub copy).png"))
        #expect(try setup.git("status", "--porcelain").isEmpty)
    }

    @Test func aNoteDeletedOnOneSideAndEditedOnTheOtherIsKept() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let other = try await setup.fixture.clone("other")
        try setup.fixture.git(other, "rm", "-q", "a.md")
        try setup.fixture.git(other, "commit", "-q", "-m", "delete a")
        try setup.fixture.git(other, "push", "-q", "origin", "main")
        try setup.edit("a.md", "# A, edited\n")
        let model = setup.model()
        await model.syncNow()

        #expect(try String(contentsOf: setup.mine.appendingPathComponent("a.md"), encoding: .utf8) == "# A, edited\n")
        #expect(try setup.remoteGit("show", "main:a.md") == "# A, edited")
    }

    @Test func aHeldBackAINoteThatGitHubChangedStopsTheMergeBeforeTouchingIt() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        let other = try await setup.fixture.clone("other")
        try setup.fixture.publish("a.md", "# A\nfrom the phone\n", from: other)
        try setup.edit("a.md", "# A\nan AI rewrite\n")
        setup.knobs.aiChanges = ["a.md": Date().addingTimeInterval(60)]
        let model = setup.model()
        await model.syncNow()

        #expect(try String(contentsOf: setup.mine.appendingPathComponent("a.md"), encoding: .utf8) ==
            "# A\nan AI rewrite\n")
        #expect(model.conflicts.isEmpty)
        #expect(model.message?.contains("keep your edits") == true)
        #expect(try setup.remoteGit("show", "main:a.md") == "# A\nfrom the phone")
    }

    @Test func theHeaderSaysWhichNotesNeedYou() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        _ = try await conflicting(setup)
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let text = SyncSummary.text(
            mode: .directCommit,
            status: model.status,
            pullRequest: nil,
            held: 0,
            conflicts: model.conflicts.count,
            repo: "octo/notes"
        )
        #expect(text == "1 note has a conflict to fix")
    }
}

@MainActor
struct MarkerTests {
    @Test func aHeadingUnderlineIsNotAConflict() throws {
        let folder = try TempFolder("markers")
        defer { folder.cleanUp() }
        try folder.write("heading.md", "Title\n=======\n\nText\n")
        try folder.write("real.md", "<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> origin/main\n")
        try folder.write("half.md", "<<<<<<< not closed\n")
        #expect(!GitSync.hasMarkers(at: folder.root.appendingPathComponent("heading.md")))
        #expect(GitSync.hasMarkers(at: folder.root.appendingPathComponent("real.md")))
        #expect(!GitSync.hasMarkers(at: folder.root.appendingPathComponent("half.md")))
        #expect(!GitSync.hasMarkers(at: folder.root.appendingPathComponent("missing.md")))
    }

    @Test func aCopyNeverReplacesAFile() throws {
        let folder = try TempFolder("copies")
        defer { folder.cleanUp() }
        try folder.write("notes/a.md", "x")
        #expect(GitSync.copyName(for: "notes/a.md", at: folder.root) == "notes/a (GitHub copy).md")
        try folder.write("notes/a (GitHub copy).md", "x")
        #expect(GitSync.copyName(for: "notes/a.md", at: folder.root) == "notes/a (GitHub copy 2).md")
    }
}

@MainActor
struct PullRequestConflictTests {
    @Test func aPullRequestWithConflictsPointsToGitHub() async throws {
        let setup = try await SyncModeSetup()
        defer { setup.cleanUp() }
        setup.knobs.mode = .pushAsPR
        try setup.edit("a.md", "# A2\n")
        let model = setup.model()
        await model.open()
        await model.syncNow()
        let branch = try #require(try setup.remoteReviewBranches().first)
        setup.api.setConflicts(branch, true)
        await model.refreshPullRequest()

        let pull = try #require(model.pullRequest)
        #expect(pull.hasConflicts == true)
        let text = SyncSummary.text(
            mode: .pushAsPR,
            status: model.status,
            pullRequest: pull,
            held: 0,
            repo: "octo/notes"
        )
        #expect(text.contains("has conflicts, resolve on GitHub"))
        #expect(pull.url.host == "github.com")
    }

    @Test func aCleanPullRequestSaysNothingAboutConflicts() throws {
        let pull = try PullRequest(
            number: 1,
            url: #require(URL(string: "https://github.com/octo/notes/pull/1")),
            state: .open,
            hasConflicts: false
        )
        let text = SyncSummary.text(mode: .pushAsPR, status: GitSync.Status(), pullRequest: pull, held: 0, repo: "x")
        #expect(!text.contains("conflicts"))
    }
}
