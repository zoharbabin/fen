import SwiftUI

/// Shown before a breaking schema change is saved (issue #7): what changes, which documents a
/// rename would touch, and nothing written until you confirm. It never rewrites silently.
struct SchemaReviewView: View {
    struct Choice: Identifiable, Equatable {
        let rename: FieldRename
        var isOn: Bool
        var id: String {
            "\(rename.type).\(rename.from)"
        }
    }

    let diff: SchemaDiff
    let newVersion: SchemaVersion
    let paths: [String]
    let root: URL?
    let confirm: ([FieldRename], MigrationPreview) -> Void
    let cancel: () -> Void
    @State private var choices: [Choice]
    @State private var preview: MigrationPreview?
    @State private var loading = false

    init(
        diff: SchemaDiff, newVersion: SchemaVersion, renames: [FieldRename], paths: [String], root: URL?,
        confirm: @escaping ([FieldRename], MigrationPreview) -> Void, cancel: @escaping () -> Void
    ) {
        self.diff = diff
        self.newVersion = newVersion
        self.paths = paths
        self.root = root
        self.confirm = confirm
        self.cancel = cancel
        _choices = State(initialValue: renames.map { Choice(rename: $0, isOn: true) })
    }

    private var chosen: [FieldRename] {
        choices.filter(\.isOn).map(\.rename)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What changes") {
                    ForEach(Array(diff.changes.enumerated()), id: \.offset) { _, change in
                        Label(
                            change.summary,
                            systemImage: change.isBreaking ? "exclamationmark.triangle" : "plus.circle"
                        )
                        .foregroundStyle(change.isBreaking ? Color.primary : Color.secondary)
                    }
                }
                if !choices.isEmpty {
                    Section {
                        ForEach($choices) { $choice in
                            Toggle(
                                "Rename \(choice.rename.type).\(choice.rename.from) to \(choice.rename.to)",
                                isOn: $choice.isOn
                            )
                        }
                    } header: {
                        Text("Rename in your documents")
                    } footer: {
                        Text("Fen changes only the key. Each change can be undone from Activity.")
                    }
                }
                previewSection
            }
            .formStyle(.grouped)
            .navigationTitle("Review version \(newVersion)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        if let preview {
                            confirm(chosen, preview)
                        }
                    }
                    .disabled(preview == nil)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .onChange(of: choices) { _, _ in preview = nil }
    }

    private var saveTitle: String {
        let count = preview?.impacts.count ?? 0
        return count > 0 ? "Save and Update \(count) Documents" : "Save Version \(newVersion)"
    }

    private var previewSection: some View {
        Section {
            if let preview {
                if preview.impacts.isEmpty {
                    Text("No document needs a change.")
                }
                ForEach(preview.impacts.prefix(10)) { impact in
                    Label(impact.relativePath, systemImage: "doc.text")
                }
                if preview.impacts.count > 10 {
                    Text("and \(preview.impacts.count - 10) more")
                }
                if !preview.conflicts.isEmpty {
                    Text("\(preview.conflicts.count) documents already have both names. Fen leaves them alone.")
                        .foregroundStyle(.orange)
                }
            }
            Button(preview == nil ? "Preview Documents" : "Preview Again", action: runPreview)
                .disabled(loading || root == nil)
            if loading {
                ProgressView().controlSize(.small)
            }
        } header: {
            Text("Documents")
        } footer: {
            Text("Look at the documents before you save. Nothing is written until you confirm.")
        }
    }

    private func runPreview() {
        guard let root else { return }
        loading = true
        let renames = chosen
        let paths = paths
        Task {
            let result = await Task.detached { SchemaMigration.preview(renames: renames, paths: paths, root: root) }
                .value
            preview = result
            loading = false
        }
    }
}
