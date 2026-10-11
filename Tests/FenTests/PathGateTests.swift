@testable import FenCore
import Foundation
import Testing

struct PathGateTests {
    @Test func resolvesAPlainRelativePath() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        let file = try folder.write("notes/a.md")

        #expect(PathGate.resolve(relativePath: "notes/a.md", in: folder.root) == file)
    }

    @Test func rejectsParentTraversalAbsolutePathsAndEmptyPaths() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.write("a.md")

        for path in ["../a.md", "notes/../../a.md", "/etc/hosts", "", "a/../../.."] {
            #expect(PathGate.resolve(relativePath: path, in: folder.root) == nil, "\(path) must be refused")
        }
    }

    @Test func allowsDotDotThatStaysInside() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        let file = try folder.write("b.md")
        try folder.folder("sub")

        #expect(PathGate.resolve(relativePath: "sub/../b.md", in: folder.root) == file)
    }

    @Test func rejectsASymlinkInsideTheRootThatPointsOutside() throws {
        let folder = try TempFolder()
        let outside = try TempFolder("outside")
        defer {
            folder.cleanUp()
            outside.cleanUp()
        }
        try outside.write("secret.md")
        try folder.symlink("link.md", to: outside.root.appendingPathComponent("secret.md"))
        try folder.symlink("linked-dir", to: outside.root)

        #expect(PathGate.resolve(relativePath: "link.md", in: folder.root) == nil)
        #expect(PathGate.resolve(relativePath: "linked-dir/secret.md", in: folder.root) == nil)
    }

    @Test func rejectsADanglingSymlinkThatPointsOutside() throws {
        let folder = try TempFolder()
        let outside = try TempFolder("outside")
        defer {
            folder.cleanUp()
            outside.cleanUp()
        }
        // The target doesn't exist yet. A write through the link would create it outside.
        try folder.symlink("new.md", to: outside.root.appendingPathComponent("not-yet.md"))

        #expect(PathGate.resolve(relativePath: "new.md", in: folder.root) == nil)
    }

    @Test func allowsASymlinkThatStaysInside() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        let target = try folder.write("real/a.md")
        try folder.symlink("alias.md", to: target)

        #expect(PathGate.resolve(relativePath: "alias.md", in: folder.root) == target)
    }

    @Test func aSiblingFolderSharingANamePrefixIsNotInside() throws {
        let parent = try TempFolder()
        defer { parent.cleanUp() }
        let notes = try parent.folder("notes")
        let evil = try parent.folder("notes-evil")

        #expect(!PathGate.isContained(evil, in: notes))
        #expect(PathGate.resolve(relativePath: "../notes-evil/x.md", in: notes) == nil)
    }

    @Test func aPathInAnotherWorkspaceIsOutside() throws {
        let parent = try TempFolder()
        defer { parent.cleanUp() }
        let first = try parent.folder("first")
        let second = try parent.folder("second")
        try parent.write("second/b.md")

        #expect(PathGate.resolve(relativePath: "../second/b.md", in: first) == nil)
        #expect(PathGate.resolve(relativePath: second.appendingPathComponent("b.md").path, in: first) == nil)
    }

    @Test func overlapIsSymmetricAndComponentWise() throws {
        let parent = try TempFolder()
        defer { parent.cleanUp() }
        let outer = try parent.folder("outer")
        let inner = try parent.folder("outer/inner")
        let sibling = try parent.folder("outer-2")

        #expect(PathGate.overlaps(outer, inner))
        #expect(PathGate.overlaps(inner, outer))
        #expect(PathGate.overlaps(outer, outer))
        #expect(!PathGate.overlaps(outer, sibling))
    }

    @Test func aNonexistentPathUnderASymlinkedAncestorIsResolved() throws {
        let folder = try TempFolder()
        let outside = try TempFolder("outside")
        defer {
            folder.cleanUp()
            outside.cleanUp()
        }
        try folder.symlink("out", to: outside.root)

        #expect(PathGate.resolve(relativePath: "out/new-file.md", in: folder.root) == nil)
    }

    @Test func aSymlinkLoopFailsClosed() throws {
        let folder = try TempFolder()
        defer { folder.cleanUp() }
        try folder.symlink("a", to: folder.root.appendingPathComponent("b"))
        try folder.symlink("b", to: folder.root.appendingPathComponent("a"))

        #expect(PathGate.resolve(relativePath: "a/x.md", in: folder.root) == nil)
    }
}

@Suite("PreviewSchemeHandler path gate")
struct PreviewSchemeHandlerGateTests {
    @Test("a sibling folder that shares the root's name prefix is rejected")
    @MainActor
    func rejectsSiblingWithSharedPrefix() throws {
        let parent = try TempFolder("sibling")
        defer { parent.cleanUp() }
        try parent.write("notes/inside.md")
        try parent.write("notes-evil/secret.md")

        let handler = PreviewSchemeHandler()
        handler.baseDirectory = parent.root.appendingPathComponent("notes")

        let inside = try #require(URL(string: "\(PreviewSchemeHandler.scheme)://local/inside.md"))
        let sibling = try #require(URL(string: "\(PreviewSchemeHandler.scheme)://local/../notes-evil/secret.md"))
        #expect(handler.internalLinkTarget(for: inside) != nil)
        #expect(handler.internalLinkTarget(for: sibling) == nil, "A folder named notes-evil is not inside notes")
    }
}
