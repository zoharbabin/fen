@testable import FenCore
import Foundation
import Testing

@Suite("Search scope choice (issue #35)")
struct SearchScopeSelectionTests {
    private let one = Workspace(name: "One", path: "/tmp/one")
    private let two = Workspace(name: "Two", path: "/tmp/two")
    private let three = Workspace(name: "Three", path: "/tmp/three")
    private var all: [Workspace] {
        [one, two, three]
    }

    @Test("all workspaces ignores the sidebar and the checklist")
    func allMode() {
        let selection = SearchScopeSelection(mode: .all, chosen: [one.id])
        #expect(selection.scope(current: two.id, available: all) == .all)
        #expect(selection.showsWorkspaceName(current: two.id, available: all))
    }

    @Test("this workspace uses the one selected in the sidebar and hides its name")
    func workspaceMode() {
        let selection = SearchScopeSelection(mode: .workspace)
        #expect(selection.scope(current: two.id, available: all) == .workspace(two.id))
        #expect(!selection.showsWorkspaceName(current: two.id, available: all))
    }

    @Test("this workspace falls back to all when nothing, or a removed workspace, is selected")
    func workspaceFallback() {
        let selection = SearchScopeSelection(mode: .workspace)
        #expect(selection.scope(current: nil, available: all) == .all)
        #expect(selection.scope(current: UUID(), available: all) == .all)
        #expect(selection.showsWorkspaceName(current: nil, available: all))
    }

    @Test("chosen workspaces searches exactly the checked ones and still shows each name")
    func chosenMode() {
        var selection = SearchScopeSelection(mode: .chosen)
        selection.toggle(one.id)
        selection.toggle(three.id)
        #expect(selection.scope(current: two.id, available: all) == .chosen([one.id, three.id]))
        #expect(selection.showsWorkspaceName(current: two.id, available: all))
        #expect(!selection.needsChoice(available: all))
        #expect(selection.summary(available: all) == "2 of 3 workspaces")
    }

    @Test("a single chosen workspace still shows its name, and the summary uses it")
    func chosenOne() {
        var selection = SearchScopeSelection(mode: .chosen)
        selection.toggle(two.id)
        #expect(selection.scope(current: nil, available: all) == .chosen([two.id]))
        #expect(selection.showsWorkspaceName(current: nil, available: all))
        #expect(selection.summary(available: all) == "Two")
    }

    @Test("toggling twice unchecks")
    func toggleTwice() {
        var selection = SearchScopeSelection(mode: .chosen)
        selection.toggle(one.id)
        selection.toggle(one.id)
        #expect(selection.chosen.isEmpty)
    }

    @Test("chosen with nothing checked searches nothing and asks you to choose")
    func chosenEmpty() {
        let selection = SearchScopeSelection(mode: .chosen)
        #expect(selection.scope(current: one.id, available: all) == .chosen([]))
        #expect(selection.needsChoice(available: all))
        #expect(selection.summary(available: all) == "Choose workspaces")
        #expect(!SearchScopeSelection(mode: .all).needsChoice(available: all))
    }

    @Test("a removed workspace drops out of the chosen set")
    func chosenDropsRemoved() {
        let selection = SearchScopeSelection(mode: .chosen, chosen: [one.id, two.id])
        let remaining = [two, three]
        #expect(selection.scope(current: nil, available: remaining) == .chosen([two.id]))
        let onlyGone = SearchScopeSelection(mode: .chosen, chosen: [one.id])
        #expect(onlyGone.needsChoice(available: remaining))
    }

    @Test("the chosen scope reaches the access policy for display with no AI filter")
    func displayReadsAnyGrantedWorkspace() {
        let closed = Workspace(name: "Closed", path: "/tmp/closed", settings: WorkspaceSettings(aiDataAccess: .none))
        let available = [one, closed]
        let selection = SearchScopeSelection(mode: .chosen, chosen: [one.id, closed.id])
        let scope = selection.scope(current: nil, available: available)
        let shown = WorkspaceAccessPolicy.eligible(available, scope: scope, destination: nil)
        #expect(Set(shown.map(\.id)) == [one.id, closed.id])
        let toModel = WorkspaceAccessPolicy.eligible(available, scope: scope, destination: .local)
        #expect(toModel.map(\.id) == [one.id])
    }
}
