@testable import FenCore
import Foundation
import Testing

@Suite("Related documents (issue #8)", .serialized)
@MainActor
struct RelatedDocumentsTests {
    @MainActor
    private struct Fixture {
        let home: TempHome
        let library: WorkspaceLibrary
        let embedder = FakeEmbedder()

        init() throws {
            home = try TempHome()
            library = WorkspaceLibrary(home: home.home, watching: false, embedder: embedder)
        }

        func add(_ folder: TempFolder, name: String? = nil, documents: Int) async throws -> Workspace {
            let workspace = try library.add(folder: folder.root, name: name)
            let ready = try await pollUntilTrue(timeout: .seconds(30)) {
                let status = library.indexStatus(for: workspace.id)
                return library.state(for: workspace.id).hasScanned && status.phase == .idle && status
                    .documents == documents
            }
            try #require(ready)
            return workspace
        }
    }

    @Test("related files come from the same workspace only, never the current file, and need no open file")
    func scopeAndSelf() async throws {
        let fixture = try Fixture()
        let mine = try TempFolder("related-mine")
        let other = try TempFolder("related-other")
        defer { fixture.home.cleanUp()
            mine.cleanUp()
            other.cleanUp()
        }
        try mine.write("current.md", "# Current\nWe publish the signed archive to customers.\n")
        try mine.write("ship.md", "# Shipping\nHow we release and deploy the signed archive.\n")
        try mine.write("cooking.md", "# Cooking\nBake bread for dinner tonight.\n")
        try other.write("elsewhere.md", "# Elsewhere\nRelease the signed archive from another project.\n")
        let workspace = try await fixture.add(mine, documents: 3)
        _ = try await fixture.add(other, documents: 1)

        let found = await fixture.library.related(
            to: "publish the signed archive", from: "current.md", in: workspace
        )
        #expect(found.map(\.relativePath) == ["ship.md"])
        #expect(found.first?.workspaceID == workspace.id)
        #expect(found.first?.reasons.contains(.sharedWords) == true)
    }

    @Test("each suggestion says why it appeared, and links count")
    func reasons() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("related-reasons")
        defer { fixture.home.cleanUp()
            folder.cleanUp()
        }
        try folder.write(
            "docs/current.md",
            "# Current\nSee [shipping](ship.md) and [[budget]]. We deploy the archive.\n"
        )
        try folder.write("docs/ship.md", "# Shipping\nDeploy the archive to production.\n")
        try folder.write("docs/budget.md", "# Budget\nTrack the cost of each deploy of the archive.\n")
        try folder.write("docs/backlinker.md", "# Back\nSee [current](current.md). The archive deploy plan.\n")
        try folder.write("other/far.md", "# Far\nThe archive deploy is described here too.\n")
        let workspace = try await fixture.add(folder, documents: 5)

        let found = await fixture.library.related(
            to: "deploy the archive",
            from: "docs/current.md",
            in: workspace,
            limit: 10
        )
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.relativePath, $0) })
        #expect(byPath["docs/ship.md"]?.reasons.contains(.linkedFromHere) == true)
        #expect(byPath["docs/budget.md"]?.reasons.contains(.linkedFromHere) == true)
        #expect(byPath["docs/backlinker.md"]?.reasons.contains(.linksHere) == true)
        #expect(byPath["docs/ship.md"]?.reasons.contains(.sameFolder) == true)
        #expect(byPath["other/far.md"]?.reasons.contains(.sameFolder) == false)
        #expect(byPath["other/far.md"]?.reasons.isEmpty == false)
        #expect(byPath["docs/ship.md"]?.reasonText.contains("Linked from this page") == true)
        let linked = Set(["docs/ship.md", "docs/budget.md", "docs/backlinker.md"])
        #expect(found.prefix(3).allSatisfy { linked.contains($0.relativePath) })
    }

    @Test("a suggestion shows the passage that matched")
    func passage() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("related-passage")
        defer { fixture.home.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md", "# A\nNothing here.\n")
        try folder.write("b.md", "# B\nThe vehicle needs a new certificate before we ship.\n")
        let workspace = try await fixture.add(folder, documents: 2)
        let found = await fixture.library.related(to: "sign the certificate", from: "a.md", in: workspace)
        #expect(found.first?.relativePath == "b.md")
        #expect(found.first?.passage.contains("certificate") == true)
    }

    @Test("blank text, a workspace without an index, or only stop words give nothing")
    func nothing() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("related-empty")
        defer { fixture.home.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md", "# A\nalpha\n")
        let workspace = try await fixture.add(folder, documents: 1)
        #expect(await fixture.library.related(to: "  ", from: "a.md", in: workspace).isEmpty)
        #expect(await fixture.library.related(to: "the and for", from: "a.md", in: workspace).isEmpty)
        let stranger = Workspace(name: "Never added", path: "/nowhere")
        #expect(await fixture.library.related(to: "alpha beta gamma", from: "a.md", in: stranger).isEmpty)
    }

    @Test("a link to a suggestion is relative to the file you edit, and safe to paste")
    func links() {
        func suggestion(_ path: String, title: String = "Title") -> RelatedSuggestion {
            RelatedSuggestion(
                workspaceID: UUID(), relativePath: path, title: title, heading: "", startLine: 1,
                passage: "", reasons: [], score: 0
            )
        }
        #expect(suggestion("notes/b.md").markdownLink(from: "notes/a.md") == "[Title](b.md)")
        #expect(suggestion("notes/sub/b.md").markdownLink(from: "notes/a.md") == "[Title](sub/b.md)")
        #expect(suggestion("b.md").markdownLink(from: "notes/deep/a.md") == "[Title](../../b.md)")
        #expect(suggestion("x/b.md").markdownLink(from: "y/a.md") == "[Title](../x/b.md)")
        #expect(suggestion("my notes/b c.md").markdownLink(from: "a.md") == "[Title](my%20notes/b%20c.md)")
        #expect(suggestion("b.md", title: "A [draft] plan").markdownLink(from: "a.md") == "[A (draft) plan](b.md)")
        #expect(suggestion("b.md", title: "").markdownLink(from: "a.md") == "[b](b.md)")
        #expect(suggestion("b.md").markdownLink(from: "a.md", text: "my words") == "[my words](b.md)")
    }

    @Test("keywords keep the longest distinct words and drop filler")
    func keywords() {
        let words = RelatedQuery.keywords(
            from: "This is the signed archive, and the archive that we notarize with Apple",
            limit: 3
        )
        #expect(words.split(separator: " ").map(String.init) == ["signed", "archive", "notarize"])
        #expect(RelatedQuery.keywords(from: "to be or not").isEmpty)
    }

    @Test("a file is found in its workspace, and a sibling folder with the same prefix is not")
    func locate() throws {
        let fixture = try Fixture()
        let parent = try TempFolder("related-locate")
        defer { fixture.home.cleanUp()
            parent.cleanUp()
        }
        try parent.write("notes/a.md", "# A\nalpha\n")
        try parent.write("notes-evil/b.md", "# B\nbeta\n")
        let workspace = try fixture.library.add(folder: parent.root.appendingPathComponent("notes"))
        let inside = fixture.library.locate(parent.root.appendingPathComponent("notes/a.md"))
        #expect(inside?.workspace.id == workspace.id)
        #expect(inside?.relativePath == "a.md")
        #expect(fixture.library.locate(parent.root.appendingPathComponent("notes-evil/b.md")) == nil)
        #expect(fixture.library.locate(parent.root.appendingPathComponent("notes/../notes-evil/b.md")) == nil)
        #expect(fixture.library.locate(URL(fileURLWithPath: "/etc/hosts")) == nil)
    }

    @Test("related documents never call a model or the network")
    func noModelNoNetwork() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Shared/Search/RelatedDocuments.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        for word in ["URLSession", "AIProvider", "AIEndpoint", "Network"] {
            #expect(!source.contains(word), "RelatedDocuments.swift mentions \(word)")
        }
    }
}
