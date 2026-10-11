@testable import FenCore
import Foundation
import Testing

struct GitRepositoryTests {
    private func state(_ folder: TempFolder, root: URL? = nil) async throws -> GitRepositoryState? {
        let source = LocalFolderSource(root: root ?? folder.root, settings: WorkspaceSettings())
        return try await source.scan { _ in }.git
    }

    @Test func aPlainFolderIsNotAGitWorkTree() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("a.md")

        #expect(GitRepository.detect(from: folder.root) == nil)
        #expect(try await state(folder) == nil)
    }

    @Test func detectsTheBranchAndACleanTree() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo(branch: "trunk")
        try folder.write("a.md")
        try folder.commitAll()

        let result = try await state(folder)

        #expect(result == GitRepositoryState(branch: "trunk", isDetached: false, isDirty: false))
    }

    @Test func detectsADetachedHead() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write("a.md")
        try folder.commitAll()
        try folder.git("checkout", "--detach")

        let result = try #require(try await state(folder))

        #expect(result.isDetached)
        #expect(result.branch.count == 7)
    }

    @Test func aModifiedTrackedFileMakesTheTreeDirty() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write("a.md", "one")
        try folder.commitAll()
        try folder.write("a.md", "two!")

        #expect(try await state(folder)?.isDirty == true)
    }

    @Test func aTouchedButUnchangedFileStaysClean() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        let file = try folder.write("a.md", "same")
        try folder.commitAll()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: file.path
        )

        #expect(try await state(folder)?.isDirty == false)
    }

    @Test func anUntrackedAndADeletedFileMakeTheTreeDirty() async throws {
        let untracked = try TempFolder()
        let deleted = try TempFolder()
        defer {
            untracked.cleanUp()
            deleted.cleanUp()
        }
        for folder in [untracked, deleted] {
            try folder.initRepo()
            try folder.write("a.md")
            try folder.commitAll()
        }
        try untracked.write("new.md")
        try FileManager.default.removeItem(at: deleted.root.appendingPathComponent("a.md"))

        #expect(try await state(untracked)?.isDirty == true)
        #expect(try await state(deleted)?.isDirty == true)
    }

    @Test func anIgnoredUntrackedFileDoesNotMakeTheTreeDirty() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write(".gitignore", "scratch.md\n")
        try folder.write("a.md")
        try folder.commitAll()
        try folder.write("scratch.md")

        #expect(try await state(folder)?.isDirty == false)
    }

    @Test func readsIndexVersion4() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        for index in 0 ..< 30 {
            try folder.write("notes/topic-\(index)/page-\(index).md", "n\(index)")
        }
        try folder.commitAll()
        try folder.git("update-index", "--index-version", "4")

        #expect(try await state(folder)?.isDirty == false)
        try folder.write("notes/topic-7/page-7.md", "changed")
        #expect(try await state(folder)?.isDirty == true)
    }

    @Test func aRootInsideAWorkTreeHonorsTheOuterGitignore() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write(".gitignore", "*.draft.md\n")
        try folder.write("vault/a.md")
        try folder.write("vault/b.draft.md")
        try folder.commitAll()

        let source = LocalFolderSource(root: folder.root.appendingPathComponent("vault"), settings: WorkspaceSettings())
        let snapshot = try await source.scan { _ in }

        #expect(snapshot.documents.map(\.relativePath) == ["a.md"])
        #expect(snapshot.git?.branch == "main")
        #expect(snapshot.git?.isDirty == false)
    }

    @Test func aGitFilePointerLikeALinkedWorktreeIsFollowed() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write("a.md")
        try folder.commitAll()
        let worktree = folder.root.appendingPathComponent("../wt-\(UUID().uuidString)").standardizedFileURL
        try folder.git("worktree", "add", "-b", "feature", worktree.path)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let source = LocalFolderSource(root: worktree, settings: WorkspaceSettings())
        let snapshot = try await source.scan { _ in }

        #expect(snapshot.git == GitRepositoryState(branch: "feature", isDetached: false, isDirty: false))
        #expect(snapshot.documents.map(\.relativePath) == ["a.md"])
    }

    @Test func gitDirectoryIsNeverListed() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write("a.md")
        try folder.write(".git/notes.md")

        #expect(try await LocalFolderSource(root: folder.root, settings: WorkspaceSettings()).scan { _ in }
            .documents.map(\.relativePath) == ["a.md"])
    }

    @Test func indexingARepoLeavesGitStatusClean() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write("a.md")
        try folder.write("sub/b.md")
        try folder.commitAll()

        let source = LocalFolderSource(root: folder.root, settings: WorkspaceSettings())
        let snapshot = try await source.scan { _ in }
        _ = try await source.update(snapshot, changedPaths: ["a.md"])

        #expect(try folder.git("status", "--porcelain").isEmpty)
    }

    /// Our matcher must list exactly what git considers visible: tracked plus untracked-not-ignored.
    @Test func ourIgnoreRulesAgreeWithGit() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write(".gitignore", """
        *.log.md
        build/
        /root-only.md
        notes/**/tmp/
        !keep.log.md
        docs/*.md
        !docs/guide.md
        """)
        try folder.write("sub/.gitignore", "local-*.md\n!local-keep.md\n")
        let candidates = [
            "a.md", "debug.log.md", "keep.log.md", "x/keep.log.md", "build/out.md", "src/build/out.md",
            "root-only.md", "sub/root-only.md", "notes/tmp/a.md", "notes/a/b/tmp/c.md", "notes/a/b/c.md",
            "docs/guide.md", "docs/other.md", "docs/sub/deep.md", "sub/local-x.md", "sub/local-keep.md",
            "sub/deeper/local-y.md", "other/local-z.md",
        ]
        for path in candidates {
            try folder.write(path)
        }

        let output = try folder.git("ls-files", "--cached", "--others", "--exclude-standard")
        let listed = output.split(separator: "\n").map(String.init).filter { $0.hasSuffix(".md") }.sorted()
        let ours = try await LocalFolderSource(root: folder.root, settings: WorkspaceSettings(includeGlobs: []))
            .scan { _ in }.documents.map(\.relativePath).sorted()

        #expect(ours == listed)
    }
}
