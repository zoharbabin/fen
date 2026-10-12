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
    @State private var showingAsk = false
    @State private var showingClone = false
    private let panelRequest = AskPanelRequest.shared
    @State private var query = ""
    @State private var scopeSelection = SearchScopeSelection()
    @State private var showingScopeChooser = false
    private let gate: WriteGate

    public init(library: WorkspaceLibrary = .shared, gate: WriteGate = .shared) {
        self.library = library
        self.gate = gate
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if showingAsk {
                AskView(library: library, service: .shared, initialWorkspace: selection, open: openPassage)
            } else if isSearching {
                searchResults
            } else if let workspace = selectedWorkspace {
                WorkspaceDetailView(library: library, gate: gate, workspace: workspace, open: open)
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
        .searchable(text: $query, prompt: "Search all files")
        .searchScopes($scopeSelection.mode) {
            Text("This Workspace").tag(WorkspaceSearchScope.workspace)
            Text("Chosen Workspaces").tag(WorkspaceSearchScope.chosen)
            Text("All Workspaces").tag(WorkspaceSearchScope.all)
        }
        .toolbar {
            if isSearching, scopeSelection.mode == .chosen {
                ToolbarItem {
                    Button(scopeSelection.summary(available: library.workspaces), systemImage: "checklist") {
                        showingScopeChooser = true
                    }
                    .popover(isPresented: $showingScopeChooser) {
                        WorkspaceChooser(workspaces: library.workspaces, selection: $scopeSelection)
                    }
                    .help("Choose which workspaces to search")
                }
            }
        }
        .task {
            library.start()
            selection = selection ?? library.currentWorkspaceID
            showAskIfRequested()
        }
        .onChange(of: panelRequest.isRequested) { _, _ in showAskIfRequested() }
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
        .sheet(isPresented: $showingClone) {
            GitHubCloneView(library: library) { selection = $0.id }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: some View {
        let available = library.workspaces
        return WorkspaceSearchView(
            library: library,
            query: query,
            scope: scopeSelection.scope(current: selection, available: available),
            origin: nil,
            showsWorkspace: scopeSelection.showsWorkspaceName(current: selection, available: available),
            needsChoice: scopeSelection.needsChoice(available: available),
            open: openResult
        )
    }

    private func showAskIfRequested() {
        if panelRequest.isRequested {
            showingAsk = true
            panelRequest.isRequested = false
        }
    }

    private func openPassage(_ passage: Passage) {
        guard let url = library.fileURL(workspaceID: passage.workspaceID, relativePath: passage.relativePath) else {
            message = "Fen can't open \(passage.fileName). It is outside the workspace or no longer listed."
            return
        }
        DocumentJumps.shared.request(line: passage.startLine, in: url)
        Task {
            if await !openAsDocument(url) {
                message = "Fen can't open \(passage.fileName) as a document."
            }
        }
    }

    private func openResult(_ result: SearchResult) {
        guard let workspace = library.registry.workspace(id: result.workspaceID) else { return }
        open(workspace, WorkspaceFile(relativePath: result.relativePath, size: 0, modified: .distantPast))
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
        .toolbar {
            ToolbarItem {
                Toggle("Ask", systemImage: "text.bubble", isOn: $showingAsk)
                    .help("Ask a question and get an answer from your workspaces, with sources")
            }
            ToolbarItem { addButton }
            ToolbarItem {
                Menu("More", systemImage: "ellipsis.circle") {
                    Toggle("Pause Auto-Approve", isOn: Binding(get: { gate.isPaused }, set: { setPaused($0) }))
                    Divider()
                    Button("Clear Caches") { clearCaches() }
                }
                .help("Clear caches. Fen rebuilds them. Your files and settings are not touched.")
            }
        }
        .overlay {
            if library.workspaces.isEmpty, let error = library.loadError {
                Text(error).foregroundStyle(.secondary).padding()
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    private func setPaused(_ paused: Bool) {
        do {
            try gate.setPaused(paused)
        } catch {
            message = error.localizedDescription
        }
    }

    private func clearCaches() {
        do {
            let count = try library.clearCaches()
            message = count == 0 ? "There were no caches to clear." : "Caches cleared. Fen rebuilds them when needed."
        } catch {
            message = error.localizedDescription
        }
    }

    private var addButton: some View {
        addMenu
            .disabled(library.loadError != nil)
    }

    @ViewBuilder
    private var addMenu: some View {
        if GitTool.locate() != nil {
            Menu {
                Button("Add Folder…") { showingImporter = true }
                Button("Clone from GitHub…") { showingClone = true }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                showingImporter = true
            }
            .help("Add a folder as a workspace, or clone a GitHub repository")
        } else {
            Button("Add Folder…", systemImage: "plus") { showingImporter = true }
                .help("Add a folder as a workspace")
        }
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
    let gate: WriteGate
    let workspace: Workspace
    let open: (Workspace, WorkspaceFile) -> Void
    @State private var showingActivity = false
    @State private var showingConflicts = false
    @State private var enrichingPath: String?
    @State private var enrichMessage: String?
    @State private var classifyTask: Task<Void, Never>?
    @State private var classifyProgress: String?
    @State private var classifyMessage: String?
    @State private var includeTyped = false

    var body: some View {
        let state = library.state(for: workspace.id)
        VStack(spacing: 0) {
            header(state)
            Divider()
            content(state)
        }
        .navigationTitle(workspace.name)
        .sheet(isPresented: $showingActivity) {
            WorkspaceActivityView(gate: gate, workspace: workspace)
        }
        .sheet(isPresented: $showingConflicts) {
            ConflictsView(library: library, gate: gate, workspace: workspace) { path in
                if let file = library.state(for: workspace.id).snapshot.documents
                    .first(where: { $0.relativePath == path }) {
                    open(workspace, file)
                }
            }
        }
        .onDisappear { classifyTask?.cancel() }
        .alert("Types and Links", isPresented: Binding(get: { classifyMessage != nil }, set: {
            if !$0 {
                classifyMessage = nil
            }
        })) {
            Button("OK") { classifyMessage = nil }
        } message: {
            Text(classifyMessage ?? "")
        }
        .alert("Enrich", isPresented: Binding(get: { enrichMessage != nil }, set: {
            if !$0 {
                enrichMessage = nil
            }
        })) {
            Button("OK") { enrichMessage = nil }
        } message: {
            Text(enrichMessage ?? "")
        }
    }

    /// Adds sourced facts under the short bullets of one file, under the workspace's approval mode.
    private func enrich(_ file: WorkspaceFile) {
        guard enrichingPath == nil else { return }
        enrichingPath = file.relativePath
        Task {
            defer { enrichingPath = nil }
            let runner = FileEnricher(library: library, service: .shared, gate: gate)
            do {
                switch try await runner.enrich(workspaceID: workspace.id, relativePath: file.relativePath) {
                case .queued: enrichMessage = "Review the changes in Activity. Nothing was written yet."
                case .applied: enrichMessage = "Facts were added under your bullets. You can undo this in Activity."
                case let .nothing(why): enrichMessage = why
                }
            } catch {
                enrichMessage = error.localizedDescription
            }
        }
    }

    /// Finds a type for each untyped note, links names in typed fields, and offers stubs for names
    /// with no note. Every result goes through the write gate.
    private func classify() {
        guard classifyTask == nil else { return }
        classifyProgress = "Reading notes…"
        classifyTask = Task {
            defer {
                classifyTask = nil
                classifyProgress = nil
            }
            var options = ClassificationRun.Options()
            options.includeTyped = includeTyped
            let runner = ClassificationRun(library: library, service: .shared, gate: gate)
            do {
                let summary = try await runner
                    .run(workspaceID: workspace.id, options: options) { done, total in
                        classifyProgress = "Reading \(done) of \(total)"
                    }
                classifyMessage = summary.text
            } catch is CancellationError {
                classifyMessage = "Stopped. Changes made before that are in Activity."
            } catch {
                classifyMessage = error.localizedDescription
            }
        }
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
            GitHubSyncControls(library: library, gate: gate, workspaceID: workspace.id).id(workspace.id)
            indexControls(library.indexStatus(for: workspace.id))
            classifyControls
            Button("Conflicts", systemImage: "exclamationmark.arrow.triangle.2.circlepath") { showingConflicts = true }
                .labelStyle(.iconOnly)
                .help("Find notes that disagree with each other")
            Button("Activity", systemImage: "clock.arrow.circlepath") { showingActivity = true }
                .labelStyle(.iconOnly)
                .badge(gate.pending(for: workspace.id).count)
                .help("AI changes: approve, review, and undo")
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
    private var classifyControls: some View {
        if let progress = classifyProgress {
            ProgressView().controlSize(.small)
            Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("Stop") { classifyTask?.cancel() }
        } else {
            Menu("Types and Links", systemImage: "tag") {
                Button("Find Types and Links") { classify() }
                Toggle("Also re-check notes that have a type", isOn: $includeTyped)
            }
            .help("Give untyped notes a type, link names in typed fields, and offer notes for missing names")
        }
    }

    @ViewBuilder
    private func indexControls(_ status: IndexStatus) -> some View {
        switch status.phase {
        case let .indexing(done, total):
            ProgressView().controlSize(.small)
            Text("Indexing \(done) of \(total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Stop Indexing") { library.cancelIndexing(id: workspace.id) }
        case .canceled:
            Text("Indexing stopped").font(.caption).foregroundStyle(.secondary)
            Button("Resume Indexing") { library.resumeIndexing(id: workspace.id) }
        case let .failed(reason):
            Text("Search index failed").font(.caption).foregroundStyle(.secondary).help(reason)
            Button("Try Again") { library.resumeIndexing(id: workspace.id) }
        case .idle:
            if status.documents > 0 {
                Text(status
                    .isSemantic ? "\(status.documents) files searchable" :
                    "\(status.documents) files searchable by words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                                Button("Enrich Bullets") { enrich(file) }
                                    .disabled(enrichingPath != nil)
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
