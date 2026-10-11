import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
    import UIKit
#endif

/// Lists your workspaces and the files in each (issue #5). Add any folder, in any number.
public struct WorkspacesView: View {
    private let library: WorkspaceLibrary
    #if os(macOS)
        @Environment(\.openDocument) private var openDocument
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: UUID?
    @State private var showingImporter = false
    @State private var message: String?
    @State private var workspaceToRemove: Workspace?
    @State private var workspaceToConfigure: Workspace?

    public init(library: WorkspaceLibrary = .shared) {
        self.library = library
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let workspace = selectedWorkspace {
                WorkspaceDetailView(library: library, workspace: workspace, open: open)
            } else {
                ContentUnavailableView {
                    Label("No workspace selected", systemImage: "folder")
                } description: {
                    Text(library.workspaces.isEmpty
                        ? "Add a folder to browse its Markdown files without opening each one."
                        : "Choose a workspace on the left.")
                } actions: {
                    if library.workspaces.isEmpty {
                        addButton
                    }
                }
            }
        }
        .navigationTitle("Workspaces")
        .task {
            library.start()
            selection = selection ?? library.currentWorkspaceID
        }
        .onChange(of: selection) { _, new in library.setCurrent(new) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refreshAll()
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): add(url)
            case let .failure(error): message = error.localizedDescription
            }
        }
        .alert("Workspaces", isPresented: Binding(get: { message != nil }, set: {
            if !$0 {
                message = nil
            }
        })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog(
            "Remove \(workspaceToRemove?.name ?? "workspace")?",
            isPresented: Binding(get: { workspaceToRemove != nil }, set: {
                if !$0 {
                    workspaceToRemove = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let workspace = workspaceToRemove {
                    remove(workspace)
                }
            }
        } message: {
            Text(
                "Fen forgets this folder and deletes its own notes about it. The folder and its files are not touched."
            )
        }
        .sheet(item: $workspaceToConfigure) { workspace in
            WorkspaceSettingsView(library: library, workspace: workspace)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var selectedWorkspace: Workspace? {
        selection.flatMap { library.registry.workspace(id: $0) }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(library.workspaces) { workspace in
                WorkspaceRow(workspace: workspace, state: library.state(for: workspace.id))
                    .tag(workspace.id)
                    .contextMenu {
                        Button("Settings…") { workspaceToConfigure = workspace }
                        Button("Refresh") { library.scan(workspace.id) }
                        Divider()
                        Button("Remove…", role: .destructive) { workspaceToRemove = workspace }
                    }
            }
        }
        .toolbar { ToolbarItem { addButton } }
        .overlay {
            if library.workspaces.isEmpty, let error = library.loadError {
                Text(error).foregroundStyle(.secondary).padding()
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    private var addButton: some View {
        Button("Add Folder…", systemImage: "plus") { showingImporter = true }
            .help("Add a folder as a workspace")
    }

    private func add(_ url: URL) {
        do {
            let workspace = try library.add(folder: url)
            selection = workspace.id
        } catch {
            message = error.localizedDescription
        }
    }

    private func remove(_ workspace: Workspace) {
        do {
            try library.remove(id: workspace.id)
            if selection == workspace.id {
                selection = library.currentWorkspaceID
            }
        } catch {
            message = "Fen couldn't remove \(workspace.name): \(error.localizedDescription)"
        }
    }

    private func open(_ workspace: Workspace, _ file: WorkspaceFile) {
        guard let url = library.fileURL(workspaceID: workspace.id, relativePath: file.relativePath) else {
            message = "Fen can't open \(file.name). It is outside the workspace or no longer listed."
            return
        }
        Task {
            if await !openAsDocument(url) {
                message = "Fen can't open \(file.name) as a document. It opens Markdown and plain text files."
            }
        }
    }

    /// SwiftUI has no `openDocument` on iOS, so the system routes the file URL back to Fen's
    /// document scene.
    private func openAsDocument(_ url: URL) async -> Bool {
        #if os(macOS)
            do {
                try await openDocument(at: url)
                return true
            } catch {
                return false
            }
        #else
            return await UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Sidebar row

private struct WorkspaceRow: View {
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

// MARK: - Detail

private struct WorkspaceDetailView: View {
    let library: WorkspaceLibrary
    let workspace: Workspace
    let open: (Workspace, WorkspaceFile) -> Void

    var body: some View {
        let state = library.state(for: workspace.id)
        VStack(spacing: 0) {
            header(state)
            Divider()
            content(state)
        }
        .navigationTitle(workspace.name)
    }

    private func header(_ state: WorkspaceState) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let git = state.snapshot.git {
                    Label(gitText(git), systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case let .scanning(found) = state.phase {
                ProgressView().controlSize(.small)
                Text("\(found) files")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") { library.cancelScan(id: workspace.id) }
            } else {
                Button("Refresh", systemImage: "arrow.clockwise") { library.scan(workspace.id) }
                    .labelStyle(.iconOnly)
                    .help("List this folder again")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(_ state: WorkspaceState) -> some View {
        switch state.phase {
        case let .failed(reason):
            ContentUnavailableView(
                "Can't read this folder",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )
        case .canceled where !state.hasScanned:
            ContentUnavailableView {
                Label("Listing canceled", systemImage: "xmark.circle")
            } actions: {
                Button("List again") { library.scan(workspace.id) }
            }
        default:
            let tree = WorkspaceFileTree.build(from: state.snapshot.documents)
            if tree.isEmpty, state.hasScanned {
                ContentUnavailableView(
                    "No Markdown files",
                    systemImage: "doc.text",
                    description: Text(
                        "Fen lists \(workspace.settings.includeGlobs.joined(separator: ", ")). "
                            + "Change this in the workspace settings."
                    )
                )
            } else {
                List(tree, children: \.children) { node in
                    FileRow(node: node)
                        .contentShape(Rectangle())
                        .onTapGesture(count: tapsToOpen) {
                            if let file = node.file {
                                open(workspace, file)
                            }
                        }
                        .contextMenu {
                            if let file = node.file {
                                Button("Open") { open(workspace, file) }
                            }
                        }
                }
            }
        }
    }

    private var tapsToOpen: Int {
        #if os(macOS)
            2
        #else
            1
        #endif
    }

    private func gitText(_ git: GitRepositoryState) -> String {
        let dirty = git.isDirty == true ? " · changes" : ""
        return (git.isDetached ? "Detached at " : "") + git.branch + dirty
    }
}

private struct FileRow: View {
    let node: FileTreeNode

    var body: some View {
        Label(node.name, systemImage: node.isFolder ? "folder" : "doc.text")
    }
}
