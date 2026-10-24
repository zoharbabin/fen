import SwiftUI

struct WorkspaceRow: View {
    let workspace: Workspace
    let state: WorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(workspace.name, systemImage: "folder")
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch state.phase {
        case let .scanning(found): "Listing… \(found) files"
        case .canceled: "Listing canceled"
        case .failed: "Unavailable"
        case .idle:
            state.hasScanned ? "\(state.snapshot.documents.count) files" : "Waiting"
        }
    }
}
