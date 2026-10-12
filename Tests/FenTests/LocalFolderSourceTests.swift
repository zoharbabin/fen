@testable import FenCore
import Foundation
import Testing

struct LocalFolderSourceTests {
    private func scan(_ folder: TempFolder, _ settings: WorkspaceSettings = WorkspaceSettings()) async throws
        -> WorkspaceSnapshot {
        try await LocalFolderSource(root: folder.root, settings: settings).scan { _ in }
    }

    private func paths(_ snapshot: WorkspaceSnapshot) -> [String] {
        snapshot.documents.map(\.relativePath)
    }

    @Test func listsMarkdownAndTextFilesWithoutOpeningThem() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("a.md")
        try folder.write("notes/b.markdown")
        try folder.write("notes/deep/c.txt")
        try folder.write("image.png.md")
        try folder.write("script.swift", "let x = 1")

        let snapshot = try await scan(folder)

        #expect(paths(snapshot) == ["a.md", "image.png.md", "notes/b.markdown", "notes/deep/c.txt"])
    }

    @Test func hiddenFilesAndFoldersAreExcluded() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("visible.md")
        try folder.write(".hidden.md")
        try folder.write(".obsidian/notes.md")
        try folder.write("sub/.draft.md")

        #expect(try await paths(scan(folder)) == ["visible.md"])
    }

    @Test func secretLookingFilesAreExcluded() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("ok.md")
        for name in [
            ".env",
            ".env.local",
            "id_rsa",
            "server.pem",
            "api.key",
            "credentials.txt",
            "passwords.md",
            "Secrets.md",
            "tokens.txt",
            ".npmrc",
        ] {
            try folder.write(name, "x")
        }
        try folder.write("Token economics.md")
        try folder.write("id_rsa.pub", "ssh-rsa AAAA")

        let snapshot = try await scan(folder, WorkspaceSettings(includeGlobs: []))

        #expect(paths(snapshot) == ["id_rsa.pub", "ok.md", "Token economics.md"])
    }

    @Test func secretFilesStayExcludedEvenWhenAnIncludeGlobNamesThem() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("passwords.md", "x")
        try folder.write("prod.pem", "x")

        let snapshot = try await scan(folder, WorkspaceSettings(includeGlobs: ["passwords.md", "*.pem"]))

        #expect(paths(snapshot).isEmpty)
    }

    @Test func binaryAndOversizedFilesAreExcluded() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("text.md")
        try folder.writeBytes("fake.md", [0x23, 0x20, 0x00, 0x01, 0x02])
        try folder.write("big.md", String(repeating: "a", count: 1000))

        let snapshot = try await scan(folder, WorkspaceSettings(maxFileBytes: 500))

        #expect(paths(snapshot) == ["text.md"])
        let source = LocalFolderSource(root: folder.root, settings: WorkspaceSettings(maxFileBytes: 500))
        #expect(source.exclusionReason(forRelativePath: "fake.md") == .binary)
        #expect(source.exclusionReason(forRelativePath: "big.md") == .tooLarge)
    }

    @Test func includeAndExcludeGlobsApplyAndExcludeWins() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("a.md")
        try folder.write("drafts/b.md")
        try folder.write("c.txt")
        try folder.write("d.private.md")

        let settings = WorkspaceSettings(includeGlobs: ["*.md"], excludeGlobs: ["drafts/", "*.private.md"])
        let snapshot = try await scan(folder, settings)

        #expect(paths(snapshot) == ["a.md"])
        let source = LocalFolderSource(root: folder.root, settings: settings)
        #expect(source.exclusionReason(forRelativePath: "c.txt") == .notIncluded)
        #expect(source.exclusionReason(forRelativePath: "drafts/b.md") == .excludedByGlob)
    }

    @Test func schemaFileIsAlwaysReadEvenThoughItIsHidden() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("a.md")
        try folder.write(".fen/schema.yaml", "types: {}")
        try folder.write(".fen/other.md")

        let snapshot = try await scan(folder)

        #expect(snapshot.schemaFile?.relativePath == ".fen/schema.yaml")
        #expect(paths(snapshot) == ["a.md"])
    }

    @Test func schemaFileIsReadEvenIfAGitignoreHidesTheFolder() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write(".gitignore", ".fen/\n")
        try folder.write(".fen/schema.yaml", "types: {}")

        #expect(try await scan(folder).schemaFile != nil)
    }

    // MARK: - Symlinks

    @Test func symlinksThatLeaveTheRootAreExcluded() async throws {
        let folder = try TempFolder()
        let outside = try TempFolder("outside")
        defer {
            folder.cleanUp()
            outside.cleanUp()
        }
        try folder.write("a.md")
        let secret = try outside.write("secret.md")
        try outside.write("dir/in-dir.md")
        try folder.symlink("leak.md", to: secret)
        try folder.symlink("leaked-dir", to: outside.root)

        let snapshot = try await scan(folder)

        #expect(paths(snapshot) == ["a.md"])
        let source = LocalFolderSource(root: folder.root, settings: WorkspaceSettings())
        #expect(source.exclusionReason(forRelativePath: "leak.md") == .symlinkOutsideRoot)
        #expect(source.exclusionReason(forRelativePath: "leaked-dir/dir/in-dir.md") == .symlinkOutsideRoot)
        #expect(throws: WorkspaceFileError.excluded(.symlinkOutsideRoot)) {
            try source.read(relativePath: "leak.md")
        }
    }

    @Test func aSymlinkedFileInsideTheRootIsListedAndAFolderLinkIsNotFollowed() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        let target = try folder.write("real/a.md")
        try folder.symlink("alias.md", to: target)
        try folder.symlink("loop", to: folder.root)

        let snapshot = try await scan(folder)

        #expect(paths(snapshot) == ["alias.md", "real/a.md"])
    }

    // MARK: - Reading and the gate

    @Test func readIsBoundToTheRootAndToEligibleFiles() throws {
        let folder = try TempFolder()
        let other = try TempFolder("other")
        defer {
            folder.cleanUp()
            other.cleanUp()
        }
        try folder.write("a.md", "hello")
        try folder.write(".env", "KEY=1")
        try other.write("b.md", "other workspace")
        let source = LocalFolderSource(root: folder.root, settings: WorkspaceSettings())

        #expect(try String(bytes: source.read(relativePath: "a.md"), encoding: .utf8) == "hello")
        #expect(throws: WorkspaceFileError.excluded(.hidden)) { try source.read(relativePath: ".env") }
        #expect(throws: WorkspaceFileError.excluded(.outsideRoot)) { try source.read(relativePath: "../b.md") }
        #expect(throws: WorkspaceFileError.excluded(.outsideRoot)) {
            try source.read(relativePath: other.root.appendingPathComponent("b.md").path)
        }
        #expect(throws: WorkspaceFileError.excluded(.outsideRoot)) { try source.read(relativePath: "/etc/hosts") }
        #expect(source.fileURL(forRelativePath: "../b.md") == nil)
    }

    @Test func aFileInAnIgnoredFolderCannotBeReadEvenByPath() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.initRepo()
        try folder.write(".gitignore", "private/\n")
        try folder.write("private/p.md")
        let source = LocalFolderSource(root: folder.root, settings: WorkspaceSettings())

        #expect(throws: WorkspaceFileError.excluded(.gitignored)) { try source.read(relativePath: "private/p.md") }
    }

    // MARK: - Read-only

    @Test func scanningWritesNothingIntoTheFolder() async throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("a.md")
        try folder.write("sub/b.md")
        let before = try snapshotOfTree(folder.root)

        _ = try await scan(folder)

        #expect(try snapshotOfTree(folder.root) == before)
    }

    @Test func sourceCodeRunsNoProcessAndNoNetwork() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Workspaces")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["Process(", "NSTask", "posix_spawn", "URLSession", "/usr/bin/git"] {
                #expect(!source.contains(forbidden), "\(file.lastPathComponent) must not contain \(forbidden)")
            }
        }
    }

    private func snapshotOfTree(_ root: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        var rows: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            rows
                .append(
                    "\(url.path)|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                )
        }
        return rows.sorted()
    }
}
