import SwiftUI

/// A checklist of your workspaces for the "Chosen Workspaces" search scope (issue #35).
struct WorkspaceChooser: View {
    let workspaces: [Workspace]
    @Binding var selection: SearchScopeSelection

    var body: some View {
        List(workspaces) { workspace in
            Toggle(workspace.name, isOn: Binding(
                get: { selection.chosen.contains(workspace.id) },
                set: { _ in selection.toggle(workspace.id) }
            ))
        }
        .frame(minWidth: 240, minHeight: 160)
    }
}
