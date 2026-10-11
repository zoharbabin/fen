import SwiftUI
import UniformTypeIdentifiers

/// Sync status and buttons for a workspace whose `origin` is on GitHub (issue #60). It shows nothing for
/// any other workspace.
struct GitHubSyncControls: View {
    @State private var model: GitHubSyncModel
    @State private var showingToken = false
    @State private var showingMessage = false

    init(library: WorkspaceLibrary, workspaceID: UUID) {
        _model = State(initialValue: GitHubSyncModel(
            root: { try? library.registry.rootURL(for: workspaceID) },
            changed: { library.scan(workspaceID) }
        ))
    }

    var body: some View {
        Group {
            if let repo = model.repo {
                HStack(spacing: 6) {
                    if let working = model.working {
                        ProgressView().controlSize(.small)
                        Text(working).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(model.status?.text ?? repo.title)
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
                    Button("Sync", systemImage: "arrow.triangle.2.circlepath") { Task { await model.syncNow() } }
                        .labelStyle(.iconOnly)
                        .disabled(model.working != nil)
                        .help("Pull from \(repo.title), commit your changes, and push")
                    Menu("GitHub", systemImage: "ellipsis") {
                        Button("Pull Only") { Task { await model.pull() } }
                        Button("Check GitHub Now") { Task { await model.refresh(fetch: true) } }
                        Divider()
                        Button("Set Token…") { showingToken = true }
                    }
                    .menuIndicator(.hidden)
                    .labelStyle(.iconOnly)
                    .fixedSize()
                }
            }
        }
        .task { await model.open() }
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
                    "Create a fine-grained token for this one repository, with Contents set to Read and write. Fen keeps it in your keychain, on this Mac only."
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
                LabeledContent("Save in") {
                    Button(parent?.path ?? "Choose Folder…") { choosingFolder = true }
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } footer: {
                Text(
                    "Fen clones into a new folder named after the repository and adds it as a workspace. "
                        + "A fine-grained token for just this repository is best. Broad tokens are refused."
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
