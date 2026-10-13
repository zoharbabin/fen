import SwiftUI
import UniformTypeIdentifiers

/// The GitHub controls in a workspace header: git on the Mac, a copy through GitHub's API on iOS.
struct GitHubWorkspaceControls: View {
    let library: WorkspaceLibrary
    let gate: WriteGate
    let workspaceID: UUID

    var body: some View {
        #if os(iOS)
            GitHubMirrorControls(library: library, gate: gate, workspaceID: workspaceID)
        #else
            GitHubSyncControls(library: library, gate: gate, workspaceID: workspaceID)
        #endif
    }
}

/// Clones a repository: with git on the Mac, through GitHub's API on iOS.
struct GitHubCloneSheet: View {
    let library: WorkspaceLibrary
    let cloned: (Workspace) -> Void

    var body: some View {
        #if os(iOS)
            GitHubMirrorCloneView(library: library, cloned: cloned)
        #else
            GitHubCloneView(library: library, cloned: cloned)
        #endif
    }
}

/// Sync status and buttons for a workspace whose `origin` is on GitHub (issue #60). It shows nothing for
/// any other workspace, and only a warning with the reason for one Fen won't sync.
struct GitHubSyncControls: View {
    let library: WorkspaceLibrary
    let workspaceID: UUID
    @State private var model: GitHubSyncModel
    @State private var showingToken = false
    @State private var showingMessage = false
    @Environment(\.openURL) private var openURL

    init(library: WorkspaceLibrary, gate: WriteGate, workspaceID: UUID) {
        self.library = library
        self.workspaceID = workspaceID
        _model = State(initialValue: GitHubSyncModel(
            inputs: GitHubSyncModel.Inputs(
                mode: { library.registry.workspace(id: workspaceID)?.settings.syncMode },
                pushesAIChanges: { library.registry.workspace(id: workspaceID)?.settings.pushesAIChanges ?? false },
                aiChanges: { AIChangedPaths.latest(in: gate.entries(for: workspaceID)) },
                clonedByFen: { library.registry.workspace(id: workspaceID)?.settings.clonedByFen ?? false }
            ),
            root: { try? library.registry.rootURL(for: workspaceID) },
            changed: { library.scan(workspaceID) }
        ))
    }

    private var settings: WorkspaceSettings? {
        library.registry.workspace(id: workspaceID)?.settings
    }

    private var mode: SyncMode {
        settings?.syncMode ?? .directCommit
    }

    var body: some View {
        Group {
            if let repo = model.repo {
                HStack(spacing: 6) {
                    if let working = model.working {
                        ProgressView().controlSize(.small)
                        Text(working).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(SyncSummary.text(
                            mode: mode,
                            status: model.status,
                            pullRequest: model.pullRequest,
                            held: model.heldBack.count,
                            conflicts: model.conflicts.count,
                            repo: repo.title
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    if model.message != nil {
                        Button("Problem", systemImage: "exclamationmark.triangle") { showingMessage = true }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .help(model.message ?? "")
                    }
                    if let pull = model.pullRequest {
                        Button("Open Pull Request", systemImage: "arrow.up.right.square") { openURL(pull.url) }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(pull.hasConflicts == true ? Color.orange : Color.primary)
                            .help(
                                pull.hasConflicts == true
                                    ? "Pull request #\(pull.number) has conflicts. Open it on GitHub to resolve them."
                                    : "Open pull request #\(pull.number) on GitHub"
                            )
                    }
                    Button(mode == .directCommit ? "Back Up" : "Sync", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.syncNow() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.working != nil)
                    .help(
                        mode == .directCommit
                            ? "Back up your notes to \(repo.title)"
                            : "Send your changes to \(repo.title) as a pull request"
                    )
                    menu
                }
            } else if let refusal = model.refusal {
                Button("GitHub sync is off", systemImage: "exclamationmark.triangle") { showingMessage = true }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .help(refusal)
            }
        }
        .task { await model.open() }
        .onChange(of: library.listingRevision) { model.noteChanged() }
        .onChange(of: model.needsToken) { _, needs in showingToken = showingToken || needs }
        .sheet(isPresented: $showingToken) {
            GitHubTokenView(repo: model.repo) { model.saveToken($0) }
        }
        .alert("GitHub", isPresented: $showingMessage) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var menu: some View {
        Menu("GitHub", systemImage: "ellipsis") {
            Picker("How to sync", selection: Binding(get: { mode }, set: { setMode($0) })) {
                ForEach(SyncMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if mode == .directCommit {
                Toggle("Back up AI changes too", isOn: Binding(
                    get: { settings?.pushesAIChanges ?? false },
                    set: { value in try? library.updateSettings(id: workspaceID) { $0.pushesAIChanges = value } }
                ))
                if !model.heldBack.isEmpty {
                    Button("Back Up AI Changes Now") { Task { await model.syncNow(includeAIChanges: true) } }
                }
            }
            Divider()
            Button("Pull Only") { Task { await model.pull() } }
            Button("Check GitHub Now") { Task { await model.refresh(fetch: true) } }
            Divider()
            Button("Set Token…") { showingToken = true }
        }
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
    }

    private func setMode(_ new: SyncMode) {
        try? library.updateSettings(id: workspaceID) { $0.syncMode = new }
    }
}

/// Asks for a fine-grained token. Broad tokens are refused.
struct GitHubTokenView: View {
    let repo: GitHubRepo?
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                SecureField("Token", text: $token)
                    .onSubmit(submit)
                if let problem {
                    Text(problem).foregroundStyle(.red).font(.caption)
                }
            } header: {
                Text("Token for \(repo?.title ?? "GitHub")")
            } footer: {
                Text(
                    "Create a fine-grained token for this one repository, with Contents set to Read and write. "
                        + "Fen keeps it in your keychain, on this device only."
                )
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380)
        .padding()
    }

    private func submit() {
        if save(token) {
            dismiss()
        } else {
            problem = GitHubToken.validationMessage(token) ?? "Fen couldn't save the token."
        }
    }
}

/// Clones a repository into a new folder and adds it as a workspace.
struct GitHubCloneView: View {
    let library: WorkspaceLibrary
    let cloned: (Workspace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var parent: URL?
    @State private var mode = SyncMode.directCommit
    @State private var choosingFolder = false
    @State private var working = false
    @State private var problem: String?

    private var repo: GitHubRepo? {
        GitHubRepo.parse(address)
    }

    var body: some View {
        Form {
            Section {
                TextField("Repository", text: $address, prompt: Text("owner/name or a github.com address"))
                SecureField("Token", text: $token, prompt: Text("Needed for a private repository"))
                Picker("How to sync", selection: $mode) {
                    ForEach(SyncMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Save in") {
                    Button(parent?.path ?? "Choose Folder…") { choosingFolder = true }
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } footer: {
                Text(
                    "Fen clones into a new folder named after the repository and adds it as a workspace. "
                        + "Back up saves your notes to GitHub as you work. Pull requests send them to a branch for review. "
                        + "You can change this later. A fine-grained token for just this repository is best. Broad tokens are refused."
                )
            }
            if let problem {
                Text(problem).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                }
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(repo == nil || parent == nil || working)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .padding()
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                parent = url
            }
        }
    }

    private func clone() {
        guard let repo, let parent, let sync = GitTool.locate().map({ GitSync(git: $0) }) else {
            problem = "Fen can't find git on this Mac. Install the Xcode command line tools."
            return
        }
        working = true
        problem = nil
        let token = token
        Task {
            let started = parent.startAccessingSecurityScopedResource()
            defer {
                if started {
                    parent.stopAccessingSecurityScopedResource()
                }
                working = false
            }
            do {
                let workspace = try await GitHubCloner(library: library, sync: sync).clone(
                    repo,
                    token: token,
                    into: parent,
                    mode: mode
                )
                cloned(workspace)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
