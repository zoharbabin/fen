import SwiftUI

/// Per-workspace settings (issue #5). Changes apply when you press Save.
struct WorkspaceSettingsView: View {
    let library: WorkspaceLibrary
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkspaceSettings
    @State private var includeText: String
    @State private var excludeText: String
    @State private var errorMessage: String?
    @State private var confirming: AutoApproveTarget?
    @State private var replacingText: String
    @State private var showingSchema = false

    private enum AutoApproveTarget: Identifiable {
        case workspace
        case rule(UUID)

        var id: String {
            switch self {
            case .workspace: "workspace"
            case let .rule(id): id.uuidString
            }
        }
    }

    init(library: WorkspaceLibrary, workspace: Workspace) {
        self.library = library
        self.workspace = workspace
        _draft = State(initialValue: workspace.settings)
        _includeText = State(initialValue: workspace.settings.includeGlobs.joined(separator: "\n"))
        _excludeText = State(initialValue: workspace.settings.excludeGlobs.joined(separator: "\n"))
        _replacingText = State(
            initialValue: workspace.settings.writePolicy.autoApproveReplacing.sorted().joined(separator: ", ")
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("AI data access", selection: $draft.aiDataAccess) {
                        ForEach(AIDataAccess.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Approve AI changes", selection: $draft.approvalMode) {
                        ForEach(ApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .onChange(of: draft.approvalMode) { old, new in
                        if new == .autoApprove, !draft.writePolicy.autoApproveConfirmed {
                            draft.approvalMode = old
                            confirming = .workspace
                        }
                    }
                    Toggle("Enrich on save", isOn: $draft.enrichOnSave)
                        .disabled(draft.aiDataAccess == .none || draft.approvalMode == .off)
                    Picker("Enrich on a schedule", selection: $draft.enrichSchedule) {
                        ForEach(EnrichSchedule.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(draft.aiDataAccess == .none || draft.approvalMode == .off)
                    Picker("Agent access (MCP)", selection: $draft.mcpAccess) {
                        ForEach(MCPAccess.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(draft.aiDataAccess == .none)
                    Picker("Agent changes (git)", selection: $draft.agentBranches) {
                        ForEach(AgentBranchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text(
                        "None keeps this workspace's content away from every model. "
                            + "Agent access is off while AI data access is None. "
                            + "Enrich on save adds cited facts under your short bullets after you save a note. "
                            + "A schedule does the same for files that changed since its last run, "
                            + "while Fen is open. It handles up to 20 files per run. "
                            + "A schedule does the same for files that changed since its last run, "
                            + "while Fen is open, up to \(EnrichOnSave.defaultMaxFilesPerRun) files per run. "
                            + "The approval mode decides if it asks first. "
                            + "In a git repository, each agent commits to its own fen/ branch. "
                            + "Your files stay as they are. "
                            + "A folder without git always asks first."
                    )
                }

                writeRulesSection

                Section {
                    Button("Edit Document Types…") { showingSchema = true }
                } header: {
                    Text("Document types")
                } footer: {
                    Text("Types and fields for the front matter of your documents. Stored in .fen/schema.yaml.")
                }

                Section {
                    TextEditor(text: $includeText)
                        .font(.body.monospaced())
                        .frame(minHeight: 70)
                        .accessibilityLabel("Include patterns")
                } header: {
                    Text("Include")
                } footer: {
                    Text("One pattern per line, in .gitignore style. Leave empty to include every text file.")
                }

                Section {
                    TextEditor(text: $excludeText)
                        .font(.body.monospaced())
                        .frame(minHeight: 70)
                        .accessibilityLabel("Exclude patterns")
                } header: {
                    Text("Exclude")
                } footer: {
                    Text(
                        "Files that match are never listed. "
                            + "Files in .gitignore, secrets, and binaries are always skipped."
                    )
                }

                Section("Size limit") {
                    Stepper(
                        "Skip files over \(draft.maxFileBytes / 1_000_000) MB",
                        value: $draft.maxFileBytes,
                        in: 100_000 ... 50_000_000,
                        step: 1_000_000
                    )
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("\(workspace.name) Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .sheet(isPresented: $showingSchema) {
            SchemaSettingsView(library: library, workspace: workspace)
        }
        .confirmationDialog(
            "Turn on auto-approve?",
            isPresented: Binding(get: { confirming != nil }, set: {
                if !$0 {
                    confirming = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Turn On") { confirmAutoApprove() }
        } message: {
            Text(
                "Fen will add text and files without asking. You can undo every change. "
                    + "Deleting, moving, and overwriting whole files still ask."
            )
        }
    }

    private var writeRulesSection: some View {
        Section {
            TextField("Auto-approve replacing text for", text: $replacingText, prompt: Text("enrich, tidy"))
                .help("Operation names, separated by commas. Replacing text needs this opt-in on top of auto-approve.")
            Stepper(
                "Ask when Fen is under \(Int((draft.writePolicy.autoApproveMinConfidence * 100).rounded()))% sure",
                value: $draft.writePolicy.autoApproveMinConfidence,
                in: 0.3 ... 1,
                step: 0.05
            )
            .help("Applies to types, links and stubs Fen works out itself. Below this, the change waits for you.")
            Stepper(
                "At most \(draft.writePolicy.maxFilesPerRun) files per run",
                value: $draft.writePolicy.maxFilesPerRun,
                in: 1 ... 200
            )
            Stepper(
                "Ask when a change touches over \(Int(draft.writePolicy.maxChangedFraction * 100))% of a document",
                value: $draft.writePolicy.maxChangedFraction,
                in: 0.1 ... 1,
                step: 0.1
            )
            ForEach($draft.writePolicy.overrides) { $rule in
                HStack {
                    Picker("Rule", selection: $rule.kind) {
                        ForEach(WriteRuleKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    TextField("Match", text: $rule.match)
                    Picker("Mode", selection: $rule.mode) {
                        ForEach(ApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: rule.mode) { old, new in
                        if new == .autoApprove, !rule.confirmed {
                            rule.mode = old
                            confirming = .rule(rule.id)
                        }
                    }
                    Button("Remove rule", systemImage: "minus.circle") {
                        draft.writePolicy.overrides.removeAll { $0.id == rule.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            Button("Add Rule", systemImage: "plus") {
                draft.writePolicy.overrides.append(.init(kind: .pathGlob, match: "", mode: .ask))
            }
        } header: {
            Text("AI write rules")
        } footer: {
            Text(
                "A rule beats the default. The most specific wins: MCP client, then path, then document type, "
                    + "then operation. Deleting, moving, and overwriting whole files always ask."
            )
        }
    }

    private func confirmAutoApprove() {
        switch confirming {
        case .workspace:
            draft.writePolicy.autoApproveConfirmed = true
            draft.approvalMode = .autoApprove
        case let .rule(id):
            if let index = draft.writePolicy.overrides.firstIndex(where: { $0.id == id }) {
                draft.writePolicy.overrides[index].confirmed = true
                draft.writePolicy.overrides[index].mode = .autoApprove
            }
        case nil:
            break
        }
        confirming = nil
    }

    private func save() {
        draft.includeGlobs = lines(includeText)
        draft.excludeGlobs = lines(excludeText)
        draft.writePolicy.autoApproveReplacing = Set(
            replacingText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        draft.writePolicy.overrides.removeAll { $0.match.trimmingCharacters(in: .whitespaces).isEmpty }
        let result = draft
        do {
            try library.updateSettings(id: workspace.id) { $0 = result }
            dismiss()
        } catch {
            errorMessage = "Fen couldn't save these settings: \(error.localizedDescription)"
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
