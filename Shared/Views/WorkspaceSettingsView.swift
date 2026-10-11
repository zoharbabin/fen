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

    init(library: WorkspaceLibrary, workspace: Workspace) {
        self.library = library
        self.workspace = workspace
        _draft = State(initialValue: workspace.settings)
        _includeText = State(initialValue: workspace.settings.includeGlobs.joined(separator: "\n"))
        _excludeText = State(initialValue: workspace.settings.excludeGlobs.joined(separator: "\n"))
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
                    Picker("Agent access (MCP)", selection: $draft.mcpAccess) {
                        ForEach(MCPAccess.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(draft.aiDataAccess == .none)
                } header: {
                    Text("AI")
                } footer: {
                    Text(
                        "None keeps this workspace's content away from every model. "
                            + "Agent access is off while AI data access is None."
                    )
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
    }

    private func save() {
        draft.includeGlobs = lines(includeText)
        draft.excludeGlobs = lines(excludeText)
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
