@testable import FenCore
import Foundation
import Testing

@MainActor
private struct Fixture {
    let home: FenHome
    let homeFolder: TempFolder
    let library: WorkspaceLibrary

    init(watching: Bool = false) throws {
        homeFolder = try TempFolder("fenhome")
        home = FenHome(root: homeFolder.root.appendingPathComponent(".fen"))
        library = WorkspaceLibrary(home: home, watching: watching)
    }

    func listed(_ id: UUID) -> [String] {
        library.state(for: id).snapshot.documents.map(\.relativePath)
    }

    func waitUntilListed(_ id: UUID) async throws -> Bool {
        try await pollUntilTrue {
            let state = library.state(for: id)
            return state.hasScanned && state.phase == .idle
        }
    }

    func cleanUp() {
        homeFolder.cleanUp()
    }
}

@Suite("WorkspaceLibrary")
@MainActor
struct WorkspaceLibraryTests {
    @Test("with no workspaces it reads, writes nothing, and starts nothing")
    func emptyDoesNothing() async throws {
        let fixture = try Fixture(watching: true)
        defer { fixture.cleanUp() }
        fixture.library.start()
        #expect(fixture.library.workspaces.isEmpty)
        #expect(fixture.library.states.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.root.path))
        #expect(await fixture.library.scheduler.runningCount == 0)
        #expect(await fixture.library.scheduler.pendingCount == 0)
    }

    @Test("adding a folder lists its eligible files without opening them")
    func addAndList() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("repo")
        defer { fixture.cleanUp()
            folder.cleanUp()
        }
        try folder.write("README.md")
        try folder.write("docs/guide.md")
        try folder.write("docs/.env", "SECRET=1")
        try folder.write("image.png", "x")

        let workspace = try fixture.library.add(folder: folder.root)
        #expect(try await fixture.waitUntilListed(workspace.id))
        #expect(fixture.listed(workspace.id) == ["docs/guide.md", "README.md"])
        #expect(fixture.library.currentWorkspaceID == workspace.id)
    }

    @Test("several workspaces are listed independently")
    func severalWorkspaces() async throws {
        let fixture = try Fixture()
        let one = try TempFolder("one")
        let two = try TempFolder("two")
        defer { fixture.cleanUp()
            one.cleanUp()
            two.cleanUp()
        }
        try one.write("a.md")
        try two.write("b.md")
        try two.write("c.md")
        let first = try fixture.library.add(folder: one.root)
        let second = try fixture.library.add(folder: two.root)
        #expect(try await fixture.waitUntilListed(first.id))
        #expect(try await fixture.waitUntilListed(second.id))
        #expect(fixture.listed(first.id) == ["a.md"])
        #expect(fixture.listed(second.id) == ["b.md", "c.md"])
        #expect(fixture.library.currentWorkspaceID == first.id)
        fixture.library.setCurrent(second.id)
        #expect(fixture.library.currentWorkspaceID == second.id)
    }

    @Test("a new library instance loads the saved workspaces and lists them")
    func persists() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("repo")
        defer { fixture.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md")
        let workspace = try fixture.library.add(folder: folder.root)
        #expect(try await fixture.waitUntilListed(workspace.id))

        let relaunched = WorkspaceLibrary(home: fixture.home, watching: false)
        relaunched.start()
        #expect(relaunched.workspaces.map(\.id) == [workspace.id])
        #expect(try await pollUntilTrue { relaunched.state(for: workspace.id).hasScanned })
        #expect(relaunched.state(for: workspace.id).snapshot.documents.map(\.relativePath) == ["a.md"])
    }

    @Test("removing deletes Fen's state and leaves the folder alone")
    func remove() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("repo")
        defer { fixture.cleanUp()
            folder.cleanUp()
        }
        let note = try folder.write("a.md", "keep me")
        let workspace = try fixture.library.add(folder: folder.root)
        #expect(try await fixture.waitUntilListed(workspace.id))
        try FileManager.default.createDirectory(
            at: fixture.home.indexDirectory(id: workspace.id), withIntermediateDirectories: true
        )

        try fixture.library.remove(id: workspace.id)
        #expect(fixture.library.workspaces.isEmpty)
        #expect(fixture.library.states[workspace.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.workspaceDirectory(id: workspace.id).path))
        #expect(try String(contentsOf: note, encoding: .utf8) == "keep me")
        #expect(fixture.library.currentWorkspaceID == nil)
    }

    @Test("canceling a scan keeps its result out")
    func cancelScan() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("repo")
        defer { fixture.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md")
        let workspace = try fixture.library.add(folder: folder.root)
        fixture.library.cancelScan(id: workspace.id)
        #expect(fixture.library.state(for: workspace.id).phase == .canceled)
        let scheduler = fixture.library.scheduler
        #expect(try await pollUntilTrue {
            let running = await scheduler.runningCount
            let pending = await scheduler.pendingCount
            return running == 0 && pending == 0
        })
        #expect(fixture.library.state(for: workspace.id).phase == .canceled)
        #expect(fixture.listed(workspace.id).isEmpty)

        fixture.library.scan(workspace.id)
        #expect(try await fixture.waitUntilListed(workspace.id))
        #expect(fixture.listed(workspace.id) == ["a.md"])
    }

    @Test("reported changes update the list without a full scan")
    func incrementalUpdate() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("repo")
        defer { fixture.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md")
        let workspace = try fixture.library.add(folder: folder.root)
        #expect(try await fixture.waitUntilListed(workspace.id))

        try folder.write("b.md")
        try FileManager.default.removeItem(at: folder.root.appendingPathComponent("a.md"))
        fixture.library.changesArrived(workspace.id, paths: ["b.md", "a.md"])
        #expect(try await pollUntilTrue { fixture.listed(workspace.id) == ["b.md"] })
    }

    @Test("the live watcher updates the list on macOS")
    func watcherUpdates() async throws {
        guard WorkspaceChangeWatcher.isLive else { return }
        let fixture = try Fixture(watching: true)
        let folder = try TempFolder("repo")
        defer { fixture.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md")
        let workspace = try fixture.library.add(folder: folder.root)
        #expect(try await fixture.waitUntilListed(workspace.id))
        try folder.write("notes/new.md")
        #expect(try await pollUntilTrue { fixture.listed(workspace.id).contains("notes/new.md") })
    }

    @Test("changing exclude globs lists the workspace again")
    func settingsRescan() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("repo")
        defer { fixture.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md")
        try folder.write("drafts/b.md")
        let workspace = try fixture.library.add(folder: folder.root)
        #expect(try await fixture.waitUntilListed(workspace.id))
        #expect(fixture.listed(workspace.id) == ["a.md", "drafts/b.md"])

        try fixture.library.updateSettings(id: workspace.id) { $0.excludeGlobs = ["drafts/"] }
        #expect(try await pollUntilTrue { fixture.listed(workspace.id) == ["a.md"] })
    }

    @Test("fileURL passes only eligible files through the gate")
    func fileURLGate() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("repo")
        let outside = try TempFolder("outside")
        defer { fixture.cleanUp()
            folder.cleanUp()
            outside.cleanUp()
        }
        try folder.write("a.md")
        try folder.write("secrets.pem", "key")
        try outside.write("loot.md")
        let workspace = try fixture.library.add(folder: folder.root)
        #expect(try await fixture.waitUntilListed(workspace.id))

        #expect(fixture.library.fileURL(workspaceID: workspace.id, relativePath: "a.md") != nil)
        #expect(fixture.library.fileURL(workspaceID: workspace.id, relativePath: "secrets.pem") == nil)
        #expect(fixture.library.fileURL(
            workspaceID: workspace.id,
            relativePath: "../\(outside.root.lastPathComponent)/loot.md"
        ) == nil)
        #expect(fixture.library.exclusionReason(workspaceID: workspace.id, relativePath: "secrets.pem") != nil)
    }

    @Test("a folder that disappeared shows a readable failure")
    func missingFolder() async throws {
        let fixture = try Fixture()
        let folder = try TempFolder("repo")
        defer { fixture.cleanUp()
            folder.cleanUp()
        }
        try folder.write("a.md")
        let workspace = try fixture.library.add(folder: folder.root)
        #expect(try await fixture.waitUntilListed(workspace.id))
        folder.cleanUp()

        let relaunched = WorkspaceLibrary(home: fixture.home, watching: false)
        relaunched.start()
        guard case let .failed(message) = relaunched.state(for: workspace.id).phase else {
            Issue.record("expected a failure, got \(relaunched.state(for: workspace.id).phase)")
            return
        }
        #expect(message.contains(workspace.name))
    }
}

@Suite("WorkspaceFileTree")
struct WorkspaceFileTreeTests {
    @Test("groups files under folders, folders first")
    func builds() {
        let files = ["z.md", "docs/b.md", "docs/a.md", "docs/deep/c.md", "a.md"].map {
            WorkspaceFile(relativePath: $0, size: 1, modified: .distantPast)
        }
        let tree = WorkspaceFileTree.build(from: files)
        #expect(tree.map(\.name) == ["docs", "a.md", "z.md"])
        let docs = tree[0]
        #expect(docs.id == "docs")
        #expect(docs.children?.map(\.name) == ["deep", "a.md", "b.md"])
        #expect(docs.children?[0].children?.map(\.id) == ["docs/deep/c.md"])
        #expect(tree[1].isFolder == false)
    }
}
