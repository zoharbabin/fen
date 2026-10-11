@testable import FenCore
import Foundation
import Testing

@Suite("Related documents controller (issue #8)", .serialized)
@MainActor
struct RelatedControllerTests {
    @MainActor
    private struct Fixture {
        let home: TempHome
        let folder: TempFolder
        let library: WorkspaceLibrary
        let controller: RelatedController
        let current: URL

        init() async throws {
            home = try TempHome()
            folder = try TempFolder("related-controller")
            try folder.write("notes/current.md", "# Current\nShipping the signed archive soon.\n")
            try folder.write("notes/ship.md", "# Shipping guide\nHow we release and deploy the signed archive.\n")
            try folder.write("cooking.md", "# Cooking\nBake bread for dinner tonight.\n")
            let library = WorkspaceLibrary(home: home.home, watching: false, embedder: FakeEmbedder())
            let workspace = try library.add(folder: folder.root)
            let ready = try await pollUntilTrue(timeout: .seconds(30)) {
                let status = library.indexStatus(for: workspace.id)
                return status.phase == .idle && status.documents == 3
            }
            try #require(ready)
            self.library = library
            controller = RelatedController(library: library)
            current = folder.root.appendingPathComponent("notes/current.md")
        }

        func cleanUp() {
            home.cleanUp()
            folder.cleanUp()
        }

        func selection(_ text: String = "release and deploy the signed archive") -> EditorSelection {
            EditorSelection(kind: .selection, text: text, range: NSRange(location: 10, length: text.utf16.count))
        }
    }

    @Test("a selection shows related files, and nothing is edited until you insert")
    func suggestsWithoutEditing() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.editorChanged(fixture.selection(), fileURL: fixture.current)
        #expect(try await pollUntilTrue { fixture.controller.suggestions.first?.relativePath == "notes/ship.md" })
        #expect(fixture.controller.trigger == .selection)
        #expect(fixture.controller.insertion == nil)
        #expect(fixture.controller.canInsert)
    }

    @Test("inserting a link replaces the selection with a relative link that keeps its words")
    func insertSelection() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let selection = fixture.selection()
        fixture.controller.editorChanged(selection, fileURL: fixture.current)
        try #require(await pollUntilTrue { !fixture.controller.suggestions.isEmpty })
        let ship = try #require(fixture.controller.suggestions.first { $0.relativePath == "notes/ship.md" })
        fixture.controller.insertLink(ship)
        let edit = try #require(fixture.controller.insertion)
        #expect(edit.range == selection.range)
        #expect(edit.expected == selection.text)
        #expect(edit.text == "[release and deploy the signed archive](ship.md)")
        #expect(fixture.controller.suggestions.isEmpty)
        fixture.controller.editorChanged(nil, fileURL: fixture.current)
        #expect(fixture.controller.insertion == nil)
    }

    @Test("a paragraph gets a titled link after its end")
    func insertParagraph() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let paragraph = EditorSelection(
            kind: .paragraph, text: "We release and deploy the signed archive every week.", range: NSRange(
                location: 60,
                length: 0
            )
        )
        fixture.controller.editorChanged(paragraph, fileURL: fixture.current)
        try #require(await pollUntilTrue { fixture.controller.trigger == .editing })
        let ship = try #require(fixture.controller.suggestions.first { $0.relativePath == "notes/ship.md" })
        fixture.controller.insertLink(ship)
        let edit = try #require(fixture.controller.insertion)
        #expect(edit.range == NSRange(location: 60, length: 0))
        #expect(edit.expected.isEmpty)
        #expect(edit.text == " [Shipping guide](ship.md)")
    }

    @Test("a dismissed card stays away for the same text, and an empty selection hides it")
    func dismissAndClear() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.editorChanged(fixture.selection(), fileURL: fixture.current)
        try #require(await pollUntilTrue { !fixture.controller.suggestions.isEmpty })
        fixture.controller.dismiss()
        #expect(fixture.controller.suggestions.isEmpty)
        fixture.controller.editorChanged(fixture.selection(), fileURL: fixture.current)
        let returned = try await pollUntilTrue(timeout: .seconds(1.5)) { !fixture.controller.suggestions.isEmpty }
        #expect(!returned)
        fixture.controller.editorChanged(
            fixture.selection("release the signed archive to customers"),
            fileURL: fixture.current
        )
        try #require(await pollUntilTrue { !fixture.controller.suggestions.isEmpty })
        fixture.controller.editorChanged(nil, fileURL: fixture.current)
        #expect(fixture.controller.suggestions.isEmpty)
        #expect(fixture.controller.trigger == nil)
    }

    @Test("a file outside every workspace, or an unsaved one, gets no card")
    func outsideWorkspace() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let outside = try TempFolder("related-outside")
        defer { outside.cleanUp() }
        try outside.write("loose.md", "# Loose\n")
        fixture.controller.editorChanged(fixture.selection(), fileURL: outside.root.appendingPathComponent("loose.md"))
        let shown = try await pollUntilTrue(timeout: .seconds(1.5)) { !fixture.controller.suggestions.isEmpty }
        #expect(!shown)
        fixture.controller.editorChanged(fixture.selection(), fileURL: nil)
        #expect(fixture.controller.suggestions.isEmpty)
    }

    @Test("resting on a heading looks up its section, without an insert option")
    func heading() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.headingHovered(
            "Plan", section: "Release and deploy the signed archive.", fileURL: fixture.current
        )
        try #require(await pollUntilTrue { fixture.controller.trigger == .heading("Plan") })
        #expect(!fixture.controller.canInsert)
        #expect(fixture.controller.suggestions.first?.relativePath == "notes/ship.md")
        fixture.controller.headingHovered("Empty", section: nil, fileURL: fixture.current)
        #expect(fixture.controller.trigger == .heading("Plan"))
    }

    @Test("a newer selection cancels an older lookup")
    func staleLookup() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.editorChanged(fixture.selection(), fileURL: fixture.current)
        fixture.controller.editorChanged(fixture.selection("bake bread for dinner"), fileURL: fixture.current)
        try #require(await pollUntilTrue { !fixture.controller.suggestions.isEmpty })
        #expect(fixture.controller.suggestions.first?.relativePath == "cooking.md")
    }
}
