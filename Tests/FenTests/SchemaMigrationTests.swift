@testable import FenCore
import Foundation
import Testing

@MainActor
@Suite("Schema migration (issue #7)", .serialized)
struct SchemaMigrationTests {
    private let rename = FieldRename(type: "Task", from: "due", to: "deadline")

    private func harness() throws -> GateHarness {
        try GateHarness(files: [
            "t1.md": "---\ntype: Task\ndue: 2026-01-01   # soon\nstatus: todo\n---\n# Body\n\ndue: not a field\n",
            "t2.md": "---\ntype: Task\ndeadline: 2026-02-02\ndue: 2026-03-03\n---\nBoth names.\n",
            "p.md": "---\ntype: Project\ndue: 2026-04-04\n---\nOther type.\n",
            "n.md": "No front matter, due: here.\n",
            "sub/t3.md": "---\r\ntype: Task\r\ndue: 2026-05-05\r\n---\r\nCRLF.\r\n",
        ])
    }

    private func paths(_: GateHarness) -> [String] {
        ["t1.md", "t2.md", "p.md", "n.md", "sub/t3.md"]
    }

    @Test("a rename is suggested for a removed field and a new one of the same kind")
    func suggests() {
        let old = SchemaStarters.defaultSchema
        var new = old
        new.version = old.version.bumpedMajor
        let index = new.types.firstIndex { $0.name == "Task" } ?? 0
        let due = new.types[index].fields.firstIndex { $0.name == "due" } ?? 0
        new.types[index].fields[due].name = "deadline"
        #expect(SchemaMigration.suggestedRenames(from: old, to: new) == [rename])
        new.types[index].fields[due].kind = .number
        #expect(SchemaMigration.suggestedRenames(from: old, to: new).isEmpty)
    }

    @Test("the preview lists only documents of that type, flags conflicts, and writes nothing")
    func previewIsReadOnly() throws {
        let gateHarness = try harness()
        defer { gateHarness.cleanUp() }
        let before = try FolderSnapshot(gateHarness.folder.root)
        let preview = SchemaMigration.preview(
            renames: [rename],
            paths: paths(gateHarness),
            root: gateHarness.folder.root
        )
        #expect(preview.impacts.map(\.relativePath) == ["t1.md", "sub/t3.md"])
        #expect(preview.conflicts == ["t2.md"])
        #expect(preview.skipped.isEmpty)
        #expect(try FolderSnapshot(gateHarness.folder.root) == before)
    }

    @Test("a path outside the workspace is skipped, never read")
    func previewStaysInside() throws {
        let gateHarness = try harness()
        let outside = try TempFolder("outside")
        defer {
            gateHarness.cleanUp()
            outside.cleanUp()
        }
        try outside.write("x.md", "---\ntype: Task\ndue: 1\n---\n")
        let preview = SchemaMigration.preview(
            renames: [rename],
            paths: ["../\(outside.root.lastPathComponent)/x.md", outside.root.appendingPathComponent("x.md").path],
            root: gateHarness.folder.root
        )
        #expect(preview.impacts.isEmpty)
        #expect(preview.skipped.count == 2)
    }

    @Test("applying renames only the key, keeps comments and body, goes through the gate, and one run undoes it")
    func applyAndRevert() throws {
        let gateHarness = try harness()
        defer { gateHarness.cleanUp() }
        let originals = Dictionary(uniqueKeysWithValues: paths(gateHarness).map { ($0, gateHarness.text($0)) })
        let preview = SchemaMigration.preview(
            renames: [rename],
            paths: paths(gateHarness),
            root: gateHarness.folder.root
        )
        let result = SchemaMigration.apply(preview, workspaceID: gateHarness.workspaceID, gate: gateHarness.gate)
        #expect(result.applied == 2)
        #expect(result.failures.isEmpty)
        #expect(gateHarness.text("t1.md") == originals["t1.md"]??.replacingOccurrences(
            of: "due: 2026-01-01",
            with: "deadline: 2026-01-01"
        ))
        #expect(gateHarness.text("sub/t3.md") == originals["sub/t3.md"]??.replacingOccurrences(
            of: "due:",
            with: "deadline:"
        ))
        for untouched in ["t2.md", "p.md", "n.md"] {
            #expect(gateHarness.text(untouched) == originals[untouched] ?? nil)
        }
        let entries = gateHarness.gate.entries(for: gateHarness.workspaceID)
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.operation)) == ["schema-migration"])

        let reverted = gateHarness.gate.revertRun(result.runID, workspaceID: gateHarness.workspaceID)
        #expect(reverted.undone == 2)
        for path in paths(gateHarness) {
            #expect(gateHarness.text(path) == originals[path] ?? nil)
        }
    }

    @Test("a file that changed after the preview is not overwritten")
    func staleFileIsKept() throws {
        let gateHarness = try harness()
        defer { gateHarness.cleanUp() }
        let preview = SchemaMigration.preview(renames: [rename], paths: ["t1.md"], root: gateHarness.folder.root)
        let edited = "---\ntype: Task\ndue: 2030-01-01\n---\nEdited meanwhile.\n"
        try gateHarness.folder.write("t1.md", edited)
        let result = SchemaMigration.apply(preview, workspaceID: gateHarness.workspaceID, gate: gateHarness.gate)
        #expect(result.applied == 0)
        #expect(result.failures.count == 1)
        #expect(gateHarness.text("t1.md") == edited)
    }

    @Test("two renames on one document make one change")
    func cumulativeRenames() throws {
        let gateHarness = try GateHarness(files: ["a.md": "---\ntype: Task\ndue: 1\nstatus: x\n---\nBody\n"])
        defer { gateHarness.cleanUp() }
        let renames = [rename, FieldRename(type: "Task", from: "status", to: "state")]
        let preview = SchemaMigration.preview(renames: renames, paths: ["a.md"], root: gateHarness.folder.root)
        #expect(preview.impacts.count == 1)
        let result = SchemaMigration.apply(preview, workspaceID: gateHarness.workspaceID, gate: gateHarness.gate)
        #expect(result.applied == 1)
        #expect(gateHarness.text("a.md") == "---\ntype: Task\ndeadline: 1\nstate: x\n---\nBody\n")
    }
}
