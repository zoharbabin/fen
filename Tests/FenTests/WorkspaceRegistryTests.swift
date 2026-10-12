@testable import FenCore
import Foundation
import Testing

@MainActor
struct WorkspaceRegistryTests {
    /// A registry whose Fen home and user home are both inside a temp folder.
    @MainActor private struct Fixture {
        let sandbox: TempFolder
        let fenHome: FenHome
        let userHome: URL
        let registry: WorkspaceRegistry

        init() throws {
            sandbox = try TempFolder("registry")
            userHome = try sandbox.folder("home")
            fenHome = FenHome(root: userHome.appendingPathComponent(".fen"))
            registry = WorkspaceRegistry(home: fenHome, userHome: userHome)
        }

        func reopened() throws -> WorkspaceRegistry {
            let other = WorkspaceRegistry(home: fenHome, userHome: userHome)
            try other.load()
            return other
        }
    }

    @Test func loadingWithNoSavedFileWritesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }

        try fixture.registry.load()

        #expect(fixture.registry.workspaces.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fenHome.root.path))
    }

    @Test func addingSeveralFoldersPersistsThemAll() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let notes = try fixture.sandbox.folder("notes")
        let work = try fixture.sandbox.folder("work")
        let clients = try fixture.sandbox.folder("clients")

        for folder in [notes, work, clients] {
            try fixture.registry.add(folder: folder)
        }

        let reopened = try fixture.reopened()
        #expect(reopened.workspaces.map(\.name) == ["notes", "work", "clients"])
        #expect(try reopened.rootURL(for: reopened.workspaces[1].id) == work)
    }

    @Test func aCorruptListIsNeverOverwrittenByAnEmptyOne() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        try fixture.fenHome.ensureExists()
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: fixture.fenHome.workspacesFile)

        #expect(throws: (any Error).self) { try fixture.registry.load() }
        #expect(fixture.registry.isListUnreadable)
        let folder = try fixture.sandbox.folder("notes")
        #expect(throws: WorkspaceError.listUnreadable) { try fixture.registry.add(folder: folder) }

        #expect(fixture.registry.workspaces.isEmpty)
        #expect(try Data(contentsOf: fixture.fenHome.workspacesFile) == corrupt)
    }

    @Test func newWorkspacesGetTheSafeDefaults() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let workspace = try fixture.registry.add(folder: fixture.sandbox.folder("notes"))

        #expect(workspace.settings.aiDataAccess == .localProvidersOnly)
        #expect(workspace.settings.approvalMode == .ask)
        #expect(workspace.settings.mcpAccess == .disabled)
        #expect(workspace.settings.syncMode == nil)
        #expect(!workspace.settings.pushesAIChanges)
    }

    @Test func syncSettingsRoundTripAndOlderFilesStillLoad() throws {
        var settings = WorkspaceSettings(syncMode: .pushAsPR, pushesAIChanges: true)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(WorkspaceSettings.self, from: data) == settings)
        settings = try JSONDecoder().decode(WorkspaceSettings.self, from: Data("{}".utf8))
        #expect(settings.syncMode == nil)
        #expect(!settings.pushesAIChanges)
    }

    @Test func settingsPersistPerWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let first = try fixture.registry.add(folder: fixture.sandbox.folder("a"))
        let second = try fixture.registry.add(folder: fixture.sandbox.folder("b"))

        try fixture.registry.updateSettings(id: first.id) {
            $0.aiDataAccess = .none
            $0.approvalMode = .autoApprove
            $0.excludeGlobs = ["drafts/**"]
        }

        let reopened = try fixture.reopened()
        #expect(reopened.workspace(id: first.id)?.settings.aiDataAccess == AIDataAccess.none)
        #expect(reopened.workspace(id: first.id)?.settings.approvalMode == .autoApprove)
        #expect(reopened.workspace(id: first.id)?.settings.excludeGlobs == ["drafts/**"])
        #expect(reopened.workspace(id: second.id)?.settings == WorkspaceSettings())
    }

    @Test func removingDeletesItsStateAndLeavesTheFolderAlone() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let folder = try fixture.sandbox.folder("notes")
        let note = try fixture.sandbox.write("notes/a.md", "keep me")
        let workspace = try fixture.registry.add(folder: folder)
        let state = fixture.fenHome.indexDirectory(id: workspace.id)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("idx".utf8).write(to: state.appendingPathComponent("db"))

        try fixture.registry.remove(id: workspace.id)

        #expect(!FileManager.default.fileExists(atPath: fixture.fenHome.workspaceDirectory(id: workspace.id).path))
        #expect(try String(contentsOf: note, encoding: .utf8) == "keep me")
        #expect(try fixture.reopened().workspaces.isEmpty)
    }

    @Test func removingOneWorkspaceKeepsTheOthersState() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let first = try fixture.registry.add(folder: fixture.sandbox.folder("a"))
        let second = try fixture.registry.add(folder: fixture.sandbox.folder("b"))
        for workspace in [first, second] {
            try FileManager.default.createDirectory(
                at: fixture.fenHome.indexDirectory(id: workspace.id), withIntermediateDirectories: true
            )
        }

        try fixture.registry.remove(id: first.id)

        #expect(FileManager.default.fileExists(atPath: fixture.fenHome.indexDirectory(id: second.id).path))
        #expect(fixture.registry.workspaces.map(\.id) == [second.id])
    }

    // MARK: - Refusals

    @Test func refusesTheSameFolderTwice() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let folder = try fixture.sandbox.folder("notes")
        try fixture.registry.add(folder: folder)

        #expect(throws: WorkspaceError.sameAsWorkspace(name: "notes")) { try fixture.registry.add(folder: folder) }
    }

    @Test func refusesAFolderInsideAWorkspaceAndNamesIt() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        try fixture.registry.add(folder: fixture.sandbox.folder("notes"))
        let inner = try fixture.sandbox.folder("notes/deep/er")

        #expect(throws: WorkspaceError.insideWorkspace(name: "notes")) { try fixture.registry.add(folder: inner) }
    }

    @Test func refusesAFolderThatContainsAWorkspaceAndNamesIt() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        try fixture.registry.add(folder: fixture.sandbox.folder("projects/alpha"))
        let outer = try fixture.sandbox.folder("projects")

        #expect(throws: WorkspaceError.containsWorkspace(name: "alpha")) { try fixture.registry.add(folder: outer) }
    }

    @Test func refusesOverlapThroughASymlink() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let real = try fixture.sandbox.folder("real")
        try fixture.registry.add(folder: real)
        try fixture.sandbox.symlink("alias", to: real)

        #expect(throws: WorkspaceError.sameAsWorkspace(name: "real")) {
            try fixture.registry.add(folder: fixture.sandbox.root.appendingPathComponent("alias"))
        }
    }

    @Test func allowsSiblingsThatShareANamePrefix() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        try fixture.registry.add(folder: fixture.sandbox.folder("notes"))
        try fixture.registry.add(folder: fixture.sandbox.folder("notes-archive"))

        #expect(fixture.registry.workspaces.count == 2)
    }

    @Test func refusesTheHomeFolder() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }

        #expect(throws: WorkspaceError.homeFolder) { try fixture.registry.add(folder: fixture.userHome) }
    }

    @Test func refusesAVolumeRoot() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }

        #expect(throws: WorkspaceError.volumeRoot) { try fixture.registry.add(folder: URL(fileURLWithPath: "/")) }
        #expect(throws: WorkspaceError.volumeRoot) {
            try fixture.registry.add(folder: URL(fileURLWithPath: "/System/Volumes/Data"))
        }
    }

    @Test func refusesFenHomeAndAnythingInsideOrAroundIt() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.fenHome.root, withIntermediateDirectories: true)
        let inside = fixture.fenHome.root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        #expect(throws: WorkspaceError.fenHome) { try fixture.registry.add(folder: fixture.fenHome.root) }
        #expect(throws: WorkspaceError.fenHome) { try fixture.registry.add(folder: inside) }
        // The folder that holds ~/.fen is the home folder here, so it is refused as home first.
        #expect(throws: WorkspaceError.homeFolder) { try fixture.registry.add(folder: fixture.userHome) }
    }

    @Test func refusesAFileAndAMissingFolder() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let file = try fixture.sandbox.write("note.md")

        #expect(throws: WorkspaceError.notAFolder) { try fixture.registry.add(folder: file) }
        #expect(throws: WorkspaceError.notAFolder) {
            try fixture.registry.add(folder: fixture.sandbox.root.appendingPathComponent("missing"))
        }
    }

    @Test func aRefusedAddWritesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }

        _ = try? fixture.registry.add(folder: fixture.userHome)

        #expect(!FileManager.default.fileExists(atPath: fixture.fenHome.root.path))
        #expect(fixture.registry.workspaces.isEmpty)
    }

    // MARK: - Lookup and storage

    @Test func findsTheWorkspaceThatContainsADocument() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let notes = try fixture.registry.add(folder: fixture.sandbox.folder("notes"))
        try fixture.registry.add(folder: fixture.sandbox.folder("work"))
        let doc = try fixture.sandbox.write("notes/sub/a.md")
        let stray = try fixture.sandbox.write("elsewhere/b.md")

        #expect(fixture.registry.workspace(containing: doc)?.id == notes.id)
        #expect(fixture.registry.workspace(containing: stray) == nil)
    }

    @Test func aCorruptRegistryThrowsAndIsLeftInPlace() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        try fixture.fenHome.ensureExists()
        try Data("{ not json".utf8).write(to: fixture.fenHome.workspacesFile)

        #expect(throws: (any Error).self) { try fixture.registry.load() }
        #expect(try String(contentsOf: fixture.fenHome.workspacesFile, encoding: .utf8) == "{ not json")
    }

    @Test func aRegistryWithoutNewerSettingKeysStillLoads() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let id = UUID()
        let json = """
        {"version":1,"workspaces":[{"id":"\(id.uuidString)","name":"old","path":"\(fixture.sandbox.root.path)",
        "addedAt":"2026-01-01T00:00:00Z","settings":{"aiDataAccess":"none"}}]}
        """
        try fixture.fenHome.ensureExists()
        try Data(json.utf8).write(to: fixture.fenHome.workspacesFile)

        let reopened = try fixture.reopened()

        #expect(reopened.workspaces.first?.settings.aiDataAccess == AIDataAccess.none)
        #expect(reopened.workspaces.first?.settings.approvalMode == .ask)
        #expect(reopened.workspaces.first?.settings.includeGlobs == WorkspaceSettings.defaultIncludeGlobs)
    }

    @Test func aMovedFolderIsFoundThroughItsBookmark() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let original = try fixture.sandbox.folder("before")
        let workspace = try fixture.registry.add(folder: original)
        let moved = fixture.sandbox.root.appendingPathComponent("after")
        try FileManager.default.moveItem(at: original, to: moved)

        let reopened = try fixture.reopened()

        #expect(try reopened.rootURL(for: workspace.id).lastPathComponent == "after")
    }

    @Test func aFolderThatIsGoneReportsLostAccess() throws {
        let fixture = try Fixture()
        defer { fixture.sandbox.cleanUp() }
        let folder = try fixture.sandbox.folder("gone")
        let workspace = try fixture.registry.add(folder: folder)
        try FileManager.default.removeItem(at: folder)

        let reopened = try fixture.reopened()

        #expect(throws: WorkspaceError.accessLost(name: "gone")) { try reopened.rootURL(for: workspace.id) }
    }

    // MARK: - Settings rules

    @Test func mcpAccessIsOffWhenAIDataAccessIsNone() {
        var settings = WorkspaceSettings(aiDataAccess: .none, mcpAccess: .enabled)
        #expect(settings.effectiveMCPAccess == .disabled)
        settings.aiDataAccess = .localProvidersOnly
        #expect(settings.effectiveMCPAccess == .enabled)
    }

    @Test func modelDestinationsFollowAIDataAccess() {
        let none = WorkspaceSettings(aiDataAccess: .none)
        let local = WorkspaceSettings(aiDataAccess: .localProvidersOnly)
        let any = WorkspaceSettings(aiDataAccess: .anyConfiguredProvider)

        #expect(!none.allowsModel(at: .local) && !none.allowsModel(at: .remote))
        #expect(local.allowsModel(at: .local) && !local.allowsModel(at: .remote))
        #expect(any.allowsModel(at: .local) && any.allowsModel(at: .remote))
    }
}
