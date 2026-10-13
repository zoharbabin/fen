#if os(iOS)
    import SwiftUI

    /// iOS can't run git, so Fen copies the repository through GitHub's API instead.
    struct GitHubCloneButton: View {
        @Binding var isPresented: Bool
        let disabled: Bool

        var body: some View {
            Button("Clone from GitHub…", systemImage: "arrow.down.circle") { isPresented = true }
                .disabled(disabled)
        }
    }

    /// Sync status and buttons for a workspace copied from GitHub on iOS (issue #60). It shows nothing
    /// for any other workspace. Nothing syncs by itself: you pull and back up when you choose.
    struct GitHubMirrorControls: View {
        let library: WorkspaceLibrary
        let workspaceID: UUID
        @State private var model: GitHubMirrorModel
        @State private var showingToken = false
        @State private var showingMessage = false
        @State private var showingConflicts = false

        init(library: WorkspaceLibrary, gate: WriteGate, workspaceID: UUID) {
            self.library = library
            self.workspaceID = workspaceID
            _model = State(initialValue: GitHubMirrorModel(
                id: workspaceID,
                inputs: GitHubMirrorModel.Inputs(
                    pushesAIChanges: { library.registry.workspace(id: workspaceID)?.settings.pushesAIChanges ?? false },
                    aiChanges: { AIChangedPaths.latest(in: gate.entries(for: workspaceID)) }
                ),
                root: { try? library.registry.rootURL(for: workspaceID) },
                changed: { library.scan(workspaceID) }
            ))
        }

        var body: some View {
            Group {
                if model.isMirror {
                    HStack(spacing: 6) {
                        if let working = model.working {
                            ProgressView().controlSize(.small)
                            Text(working).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(model.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if model.message != nil {
                            Button("Problem", systemImage: "exclamationmark.triangle") { showingMessage = true }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.orange)
                        }
                        if !model.conflicts.isEmpty {
                            Button("Fix Conflicts", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
                                showingConflicts = true
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                        }
                        Button("Back Up", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await model.syncNow() }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(model.working != nil)
                        menu
                    }
                }
            }
            .task {
                await model.open()
                await model.refreshPending()
            }
            .onChange(of: library.listingRevision) { Task { await model.refreshPending() } }
            .onChange(of: model.needsToken) { _, needs in showingToken = showingToken || needs }
            .sheet(isPresented: $showingToken) {
                GitHubTokenView(repo: model.repo) { model.saveToken($0) }
            }
            .sheet(isPresented: $showingConflicts) {
                GitHubMirrorConflictsView(model: model)
            }
            .alert("GitHub", isPresented: $showingMessage) {
                Button("OK") {}
            } message: {
                Text(model.message ?? "")
            }
        }

        private var menu: some View {
            Menu("GitHub", systemImage: "ellipsis") {
                Toggle("Back up AI changes too", isOn: Binding(
                    get: { library.registry.workspace(id: workspaceID)?.settings.pushesAIChanges ?? false },
                    set: { value in try? library.updateSettings(id: workspaceID) { $0.pushesAIChanges = value } }
                ))
                if !model.heldBack.isEmpty {
                    Button("Back Up AI Changes Now") { Task { await model.syncNow(includeAIChanges: true) } }
                }
                Divider()
                Button("Pull Only") { Task { await model.pull() } }
                Button("Set Token…") { showingToken = true }
            }
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .fixedSize()
        }
    }

    /// Lists notes that changed here and on GitHub, and keeps one version of each.
    struct GitHubMirrorConflictsView: View {
        let model: GitHubMirrorModel
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                List {
                    if model.conflicts.isEmpty {
                        ContentUnavailableView("No conflicts", systemImage: "checkmark.circle")
                    }
                    ForEach(model.conflicts, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(path).font(.headline).lineLimit(1).truncationMode(.middle)
                            Text(model.state?.conflicts[path]?.isEmpty == true
                                ? "You changed this note and GitHub deleted it."
                                : "You and GitHub both changed this note.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Keep Mine") { Task { await model.resolve(path, keepMine: true) } }
                                Button("Use GitHub's", role: .destructive) {
                                    Task { await model.resolve(path, keepMine: false) }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .navigationTitle("Conflicts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .onChange(of: model.conflicts.isEmpty) { _, empty in
                if empty {
                    dismiss()
                }
            }
        }
    }

    /// Copies a GitHub repository into the Fen folder on this device and adds it as a workspace.
    struct GitHubMirrorCloneView: View {
        let library: WorkspaceLibrary
        let cloned: (Workspace) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var address = ""
        @State private var token = ""
        @State private var working = false
        @State private var problem: String?

        private var repo: GitHubRepo? {
            GitHubRepo.parse(address)
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("Repository", text: $address, prompt: Text("owner/name or a github.com address"))
                            .accessibilityIdentifier("CloneAddress")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Token", text: $token, prompt: Text("Needed for a private repository"))
                    } footer: {
                        Text(
                            "Fen copies the repository into its own folder on this device and adds it as a workspace. "
                                + "Back Up sends your changes to GitHub as one commit. "
                                + "A fine-grained token for just this repository, with Contents set to Read and write, "
                                + "is best. Broad tokens are refused."
                        )
                    }
                    if let problem {
                        Text(problem).foregroundStyle(.red).font(.caption)
                    }
                }
                .navigationTitle("Clone from GitHub")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if working {
                            ProgressView()
                        } else {
                            Button("Clone", action: clone).disabled(repo == nil)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(working)
        }

        private func clone() {
            guard let repo, let parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            working = true
            problem = nil
            let token = token
            Task {
                defer { working = false }
                do {
                    let workspace = try await GitHubMirrorCloner(library: library).clone(
                        repo,
                        token: token,
                        into: parent
                    )
                    cloned(workspace)
                    dismiss()
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
    }
#endif
