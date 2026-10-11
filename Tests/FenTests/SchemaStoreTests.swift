@testable import FenCore
import Foundation
import Testing

@Suite("Schema file (issue #7)", .serialized)
struct SchemaStoreTests {
    @Test("loading a folder with no schema file gives the built-in types and creates nothing")
    func noFileCreatesNothing() throws {
        let folder = try TempFolder("schema")
        defer { folder.cleanUp() }
        try folder.write("a.md")
        let before = try FolderSnapshot(folder.root)
        let loaded = try SchemaStore(root: folder.root).load()
        #expect(!loaded.hasFile)
        #expect(loaded.schema == SchemaStarters.defaultSchema)
        #expect(try FolderSnapshot(folder.root) == before)
    }

    @Test("creating the schema adds .fen/schema.yaml and nothing else")
    func createAddsOneFile() throws {
        let folder = try TempFolder("schema")
        defer { folder.cleanUp() }
        try folder.write("notes/a.md")
        let before = try FolderSnapshot(folder.root).paths
        let store = SchemaStore(root: folder.root)
        try store.create(SchemaStarters.defaultSchema)
        let after = try FolderSnapshot(folder.root).paths
        #expect(Set(after).subtracting(before) == ["/.fen", "/.fen/schema.yaml"])
        #expect(Set(before).isSubset(of: Set(after)))
        let loaded = try store.load()
        #expect(loaded.hasFile)
        #expect(loaded.schema == SchemaStarters.defaultSchema)
    }

    @Test("create never overwrites a file you already have")
    func createKeepsExisting() throws {
        let folder = try TempFolder("schema")
        defer { folder.cleanUp() }
        let mine = "schema_version: 1.4.0\ntypes: {}\n"
        try folder.write(".fen/schema.yaml", mine)
        try SchemaStore(root: folder.root).create(SchemaStarters.defaultSchema)
        let text = try String(contentsOf: folder.root.appendingPathComponent(".fen/schema.yaml"), encoding: .utf8)
        #expect(text == mine)
    }

    @Test("save refuses a breaking change without a major bump and leaves the file as it was")
    func saveEnforcesVersions() throws {
        let folder = try TempFolder("schema")
        defer { folder.cleanUp() }
        let store = SchemaStore(root: folder.root)
        let old = SchemaStarters.defaultSchema
        try store.create(old)
        let file = folder.root.appendingPathComponent(".fen/schema.yaml")
        let original = try Data(contentsOf: file)

        var breaking = old
        breaking.types.removeLast()
        breaking.version = old.version.bumpedMinor
        #expect(throws: SchemaError.breakingNeedsMajor) { try store.save(breaking, replacing: old) }
        breaking.version = old.version
        #expect(throws: SchemaError.versionNotRaised) { try store.save(breaking, replacing: old) }
        #expect(try Data(contentsOf: file) == original)

        breaking.version = old.version.bumpedMajor
        try store.save(breaking, replacing: old)
        #expect(try store.load().schema == breaking)
    }

    @Test("save rejects an invalid schema before writing")
    func saveValidates() throws {
        let folder = try TempFolder("schema")
        defer { folder.cleanUp() }
        let store = SchemaStore(root: folder.root)
        let bad = DocumentSchema(types: [DocumentType("not valid", description: "")])
        #expect(throws: SchemaError.badName("not valid")) { try store.create(bad) }
        let empty = DocumentSchema(types: [DocumentType("T", description: "", fields: [SchemaField("c", .choice)])])
        #expect(throws: SchemaError.self) { try store.create(empty) }
        #expect(!store.fileExists)
    }

    @Test("a .fen folder that is a symlink out of the workspace is refused for reading and writing")
    func symlinkEscape() throws {
        let folder = try TempFolder("schema")
        let outside = try TempFolder("outside")
        defer {
            folder.cleanUp()
            outside.cleanUp()
        }
        try FileManager.default.createSymbolicLink(
            at: folder.root.appendingPathComponent(".fen"),
            withDestinationURL: outside.root
        )
        let store = SchemaStore(root: folder.root)
        #expect(throws: SchemaError.outsideWorkspace) { try store.load() }
        #expect(throws: SchemaError.outsideWorkspace) { try store.create(SchemaStarters.defaultSchema) }
        #expect(try FolderSnapshot(outside.root).paths.isEmpty)
    }

    @Test("a huge or broken file is an error, not a crash")
    func badFiles() throws {
        let folder = try TempFolder("schema")
        defer { folder.cleanUp() }
        let store = SchemaStore(root: folder.root)
        try folder.write(".fen/schema.yaml", String(repeating: "# pad\n", count: SchemaStore.maxBytes / 4))
        #expect(throws: SchemaError.notYAML) { try store.load() }
        try folder.write(".fen/schema.yaml", "schema_version: [oops\n")
        #expect(throws: SchemaError.self) { try store.load() }
    }
}
