@testable import FenCore
import Foundation
import Testing

@Suite("Backlinks (issue #36)", .serialized)
@MainActor
struct BacklinksTests {
    @MainActor
    private struct Fixture {
        let home: TempHome
        let library: WorkspaceLibrary

        init() throws {
            home = try TempHome()
            library = WorkspaceLibrary(home: home.home, watching: false, embedder: FakeEmbedder())
        }

        func add(_ folder: TempFolder, documents: Int) async throws -> Workspace {
            let workspace = try library.add(folder: folder.root)
            let ready = try await pollUntilTrue(timeout: .seconds(30)) {
                let status = library.indexStatus(for: workspace.id)
                return library.state(for: workspace.id).hasScanned && status.phase == .idle && status
                    .documents == documents
            }
            try #require(ready)
            return workspace
        }
    }

    private func files(in folder: TempFolder) throws -> Set<String> {
        let enumerator = FileManager.default.enumerator(atPath: folder.root.path)
        return Set((enumerator?.allObjects as? [String]) ?? [])
    }

    @Test("lists every document that links here, by [[name]] or by path, without any of them being open")
    func findsLinksFromUnopenedFiles() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("backlinks-basic")
        defer { fixture.home.cleanUp()
            folder.cleanUp()
        }
        let target = try folder.write("notes/target.md", "# The Target\nBody.\n")
        try folder.write("a.md", "# Zebra note\nSee [[target]].\n")
        try folder.write("sub/b.md", "# Apple note\nSee [the target](../notes/target.md).\n")
        try folder.write("c.md", "# Not linked\nNothing here.\n")
        try folder.write("d.md", "# Alias\nSee [[Notes/Target|that one]] and [[Target#The Target]].\n")
        let before = try files(in: folder)
        let workspace = try await fixture.add(folder, documents: 5)

        let found = await fixture.library.backlinks(to: target)
        #expect(found.map(\.relativePath) == ["d.md", "sub/b.md", "a.md"])
        #expect(found.map(\.title) == ["Alias", "Apple note", "Zebra note"])
        #expect(found.allSatisfy { $0.workspaceID == workspace.id })
        // Issue #9: the index lives in ~/.fen. The folder gets no manifest or index file.
        #expect(try files(in: folder) == before)
    }

    @Test("a name shared by two files only counts for the file the preview would open")
    func ambiguousNames() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("backlinks-ambiguous")
        defer { fixture.home.cleanUp()
            folder.cleanUp()
        }
        let near = try folder.write("notes/ideas.md", "# Near ideas\n")
        let far = try folder.write("archive/ideas.md", "# Far ideas\n")
        try folder.write("notes/reader.md", "# Reader\nSee [[ideas]].\n")
        _ = try await fixture.add(folder, documents: 3)

        let toNear = await fixture.library.backlinks(to: near)
        let toFar = await fixture.library.backlinks(to: far)
        #expect(toNear.map(\.relativePath) == ["notes/reader.md"])
        #expect(toFar.isEmpty)
    }

    @Test("a name never reaches a file in another workspace")
    func otherWorkspaces() async throws {
        let fixture = try Fixture()
        let mine = try TempFolder("backlinks-mine")
        let other = try TempFolder("backlinks-other")
        defer { fixture.home.cleanUp()
            mine.cleanUp()
            other.cleanUp()
        }
        let target = try mine.write("target.md", "# Target\n")
        try other.write("stranger.md", "# Stranger\nSee [[target]].\n")
        try other.write("target.md", "# Their target\n")
        try mine.write("friend.md", "# Friend\nSee [[target]].\n")
        _ = try await fixture.add(mine, documents: 2)
        _ = try await fixture.add(other, documents: 2)

        let found = await fixture.library.backlinks(to: target)
        #expect(found.map(\.relativePath) == ["friend.md"])
        let resolver = try #require(fixture.library.wikiLinkResolver(for: target))
        #expect(resolver.resolve("stranger") == nil)
        #expect(resolver.resolve("friend") == "friend.md")
    }

    @Test("a file outside every workspace has no backlinks and no resolver")
    func outsideAnyWorkspace() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("backlinks-inside")
        let outside = try TempFolder("backlinks-outside")
        defer { fixture.home.cleanUp()
            folder.cleanUp()
            outside.cleanUp()
        }
        try folder.write("a.md", "# A\n")
        let loose = try outside.write("loose.md", "# Loose\nSee [[a]].\n")
        _ = try await fixture.add(folder, documents: 1)

        #expect(await fixture.library.backlinks(to: loose).isEmpty)
        #expect(fixture.library.wikiLinkResolver(for: loose) == nil)
        #expect(await fixture.library.backlinks(to: nil).isEmpty)
    }

    @Test("the resolver waits for the first listing, and the revision tells a view when it is ready")
    func resolverNeedsListing() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("backlinks-listing")
        defer { fixture.home.cleanUp()
            folder.cleanUp()
        }
        let note = try folder.write("a.md", "# A\n")
        let before = fixture.library.listingRevision
        _ = try fixture.library.add(folder: folder.root)
        let ready = try await pollUntilTrue(timeout: .seconds(30)) { fixture.library.listingRevision > before }
        try #require(ready)
        #expect(fixture.library.wikiLinkResolver(for: note)?.resolve("a") == "a.md")
    }
}
