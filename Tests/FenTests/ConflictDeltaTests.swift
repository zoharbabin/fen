@testable import FenCore
import Foundation
import Testing

@Suite("Which notes changed since the last check (issue #94)", .serialized)
struct ConflictDeltaTests {
    private func hasher(_ root: URL) -> @Sendable (String) -> String? {
        { path in (try? Data(contentsOf: root.appendingPathComponent(path))).map { ContentHash.of($0) } }
    }

    private func currentHead(_ fixture: GitFixture) throws -> String {
        try fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func seen(_ fixture: GitFixture, _ paths: [String], head: String?) -> ConflictState {
        var state = ConflictState()
        state.commit = head
        for path in paths {
            state.files[path] = .init(hash: hasher(fixture.root)(path) ?? "", passages: [])
        }
        return state
    }

    private func find(
        _ fixture: GitFixture,
        _ state: ConflictState,
        git: GitTool? = GitFixture.tool
    ) async -> ConflictDelta {
        let paths = ["a.md", "notes/b.md", "notes/c.md"].filter {
            FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent($0).path)
        }
        return await ConflictDeltaFinder.find(
            root: fixture.root, paths: paths, state: state, git: git, hash: hasher(fixture.root)
        )
    }

    @Test("With git, a note committed after the last run is changed and the others are not")
    func committedChange() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let head = try currentHead(fixture)
        let state = seen(fixture, ["a.md", "notes/b.md"], head: head)
        try fixture.folder.write("a.md", "# A\nNew claim.\n")
        try fixture.git("commit", "-q", "-am", "edit a")
        let delta = await find(fixture, state)
        #expect(delta.changed == ["a.md"])
        #expect(delta.usedGit)
        #expect(try delta.head == currentHead(fixture))
    }

    @Test("An edit that is not committed yet counts, and a new untracked note counts")
    func uncommittedAndUntracked() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let state = try seen(fixture, ["a.md", "notes/b.md"], head: currentHead(fixture))
        try fixture.folder.write("notes/b.md", "# B\nEdited, not committed.\n")
        try fixture.folder.write("notes/c.md", "# C\nBrand new.\n")
        let delta = await find(fixture, state)
        #expect(delta.changed == ["notes/b.md", "notes/c.md"])
    }

    @Test("A committed file whose hash matches the last run is not checked twice")
    func hashFilters() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let head = try currentHead(fixture)
        try fixture.folder.write("a.md", "# A\nChecked while uncommitted.\n")
        let state = seen(fixture, ["a.md", "notes/b.md"], head: head)
        try fixture.git("commit", "-q", "-am", "commit it")
        #expect(await find(fixture, state).changed.isEmpty)
    }

    @Test("A baseline commit that is gone falls back to hashes")
    func missingBaseline() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        var state = seen(fixture, ["a.md"], head: String(repeating: "a", count: 40))
        state.files["a.md"]?.hash = "old"
        let delta = await find(fixture, state)
        #expect(!delta.usedGit)
        #expect(delta.changed == ["a.md", "notes/b.md"])
    }

    @Test("Without git every note is hashed, and only changed hashes count")
    func noGit() async throws {
        let folder = try TempFolder("conflict-nogit")
        defer { folder.cleanUp() }
        try folder.write("a.md", "# A\none\n")
        try folder.write("b.md", "# B\ntwo\n")
        var state = ConflictState()
        state.files["a.md"] = .init(hash: ContentHash.of(Data("# A\none\n".utf8)), passages: [])
        state.files["b.md"] = .init(hash: "stale", passages: [])
        let delta = await ConflictDeltaFinder.find(
            root: folder.root, paths: ["a.md", "b.md"], state: state, git: nil, hash: hasher(folder.root)
        )
        #expect(delta.changed == ["b.md"])
        #expect(!delta.usedGit)
        #expect(delta.head == nil)
    }

    @Test("The first run has no baseline, so every note is a candidate")
    func firstRun() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanUp() }
        let delta = await find(fixture, ConflictState())
        #expect(delta.changed == ["a.md", "notes/b.md"])
        #expect(!delta.usedGit)
        #expect(delta.head != nil)
    }

    @Test("A workspace that is a subfolder of the repository uses paths relative to it")
    func subfolder() async throws {
        let fixture = try GitFixture(["docs/a.md": "# A\n", "other/x.md": "# X\n"])
        defer { fixture.cleanUp() }
        let root = fixture.root.appendingPathComponent("docs")
        let hash = hasher(root)
        var state = ConflictState()
        state.commit = try currentHead(fixture)
        state.files["a.md"] = .init(hash: hash("a.md") ?? "", passages: [])
        try fixture.folder.write("docs/a.md", "# A\nchanged\n")
        try fixture.folder.write("other/x.md", "# X\nchanged\n")
        let delta = await ConflictDeltaFinder.find(
            root: root, paths: ["a.md"], state: state, git: GitFixture.tool, hash: hash
        )
        #expect(delta.changed == ["a.md"])
        #expect(delta.usedGit)
    }
}
