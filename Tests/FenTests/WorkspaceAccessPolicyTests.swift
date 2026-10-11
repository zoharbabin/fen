@testable import FenCore
import Foundation
import Testing

struct WorkspaceAccessPolicyTests {
    private let none = Workspace(name: "none", path: "/a", settings: WorkspaceSettings(aiDataAccess: .none))
    private let local = Workspace(
        name: "local",
        path: "/b",
        settings: WorkspaceSettings(aiDataAccess: .localProvidersOnly)
    )
    private let any = Workspace(
        name: "any",
        path: "/c",
        settings: WorkspaceSettings(aiDataAccess: .anyConfiguredProvider)
    )

    private var all: [Workspace] {
        [none, local, any]
    }

    @Test func aNoneWorkspaceIsSkippedInAnAllWorkspacesModelQuery() {
        let local = WorkspaceAccessPolicy.eligible(all, scope: .all, destination: .local)
        let remote = WorkspaceAccessPolicy.eligible(all, scope: .all, destination: .remote)

        #expect(local.map(\.name) == ["local", "any"])
        #expect(remote.map(\.name) == ["any"])
    }

    @Test func aScopeNeverOverridesTheSetting() {
        let named = WorkspaceAccessPolicy.eligible(all, scope: .workspace(none.id), destination: .local)
        let chosen = WorkspaceAccessPolicy.eligible(all, scope: .chosen([none.id, local.id]), destination: .local)

        #expect(named.isEmpty)
        #expect(chosen.map(\.name) == ["local"])
    }

    @Test func queriesWithoutAModelCoverEveryWorkspaceInScope() {
        #expect(WorkspaceAccessPolicy.eligible(all, scope: .all, destination: nil).count == 3)
        #expect(WorkspaceAccessPolicy.eligible(all, scope: .workspace(none.id), destination: nil)
            .map(\.name) == ["none"])
    }

    @Test @MainActor func theRegistryUsesTheSamePolicy() throws {
        let sandbox = try TempFolder()
        defer { sandbox.cleanUp() }
        let registry = WorkspaceRegistry(
            home: FenHome(root: sandbox.root.appendingPathComponent(".fen")),
            userHome: sandbox.root
        )
        let first = try registry.add(folder: sandbox.folder("a"))
        try registry.add(folder: sandbox.folder("b"))
        try registry.updateSettings(id: first.id) { $0.aiDataAccess = .none }

        #expect(registry.eligibleWorkspaces(scope: .all, destination: .local).map(\.name) == ["b"])
    }
}
