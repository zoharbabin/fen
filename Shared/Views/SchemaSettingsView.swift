import SwiftUI

/// View, edit, add, and hide the document types of a workspace (issue #7). The types live in
/// `.fen/schema.yaml`. Fen creates that file only after you confirm, and it is the only file Fen
/// adds to your folder.
struct SchemaSettingsView: View {
    let library: WorkspaceLibrary
    let workspace: Workspace
    let gate: WriteGate
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SchemaDraft(SchemaStarters.defaultSchema)
    @State private var original = SchemaStarters.defaultSchema
    @State private var hasFile = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var confirmingCreate = false
    @State private var review: Review?
    @State private var resultMessage: String?

    private struct Review: Identifiable {
        let id = UUID()
        let diff: SchemaDiff
        let schema: DocumentSchema
        let renames: [FieldRename]
    }

    init(library: WorkspaceLibrary, workspace: Workspace, gate: WriteGate = .shared) {
        self.library = library
        self.workspace = workspace
        self.gate = gate
    }

    private var store: SchemaStore? {
        library.schemaStore(for: workspace.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                introSection
                ForEach($draft.types) { $type in
                    typeSection($type)
                }
                Section {
                    Button("Add Type", systemImage: "plus") { draft.addType() }
                    Menu("Add Starter Pack", systemImage: "square.stack") {
                        ForEach(SchemaStarters.packs) { pack in
                            Button(pack.title) { draft.add(pack) }
                        }
                    }
                }
                if !draft.problems.isEmpty {
                    Section("Fix before saving") {
                        ForEach(draft.problems, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Document Types")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!loaded || !draft.problems.isEmpty || !hasChanges)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .task { load() }
        .confirmationDialog("Create the schema file?", isPresented: $confirmingCreate, titleVisibility: .visible) {
            Button("Create .fen/schema.yaml") { create() }
        } message: {
            Text(
                "This adds one plain text file to \(workspace.name). It is the only file Fen adds there. "
                    + "Commit it to share your types."
            )
        }
        .sheet(item: $review) { review in
            SchemaReviewView(
                diff: review.diff,
                newVersion: review.schema.version,
                renames: review.renames,
                paths: library.state(for: workspace.id).snapshot.documents.map(\.relativePath),
                root: store?.root,
                confirm: { renames, preview in finish(review, renames: renames, preview: preview) },
                cancel: { self.review = nil }
            )
        }
        .alert("Document Types", isPresented: Binding(get: { resultMessage != nil }, set: {
            if !$0 {
                resultMessage = nil
                dismiss()
            }
        })) {
            Button("OK") {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var hasChanges: Bool {
        !hasFile || !SchemaDiff(from: original, to: draft.schema).isEmpty
    }

    private var introSection: some View {
        Section {
            if hasFile {
                LabeledContent("Version", value: original.version.description)
            } else {
                Text("This workspace uses Fen's built-in types. Save to create a schema file you can edit and share.")
            }
        } footer: {
            Text(
                "A document picks a type with type: in its front matter. "
                    + "Documents with an unknown type open and edit as usual."
            )
        }
    }

    private func typeSection(_ type: Binding<SchemaDraft.TypeDraft>) -> some View {
        Section {
            DisclosureGroup {
                TextField("Description", text: type.description)
                Toggle("Hide this type", isOn: type.hidden)
                ForEach(type.fields) { $field in
                    fieldRow($field)
                }
                HStack {
                    Button("Add Field", systemImage: "plus") { draft.addField(toType: type.wrappedValue.id) }
                    Spacer()
                    Button("Remove Type", systemImage: "trash", role: .destructive) {
                        draft.removeType(type.wrappedValue.id)
                    }
                }
                .buttonStyle(.borderless)
            } label: {
                TextField("Type name", text: type.name).font(.headline)
            }
        }
    }

    private func fieldRow(_ field: Binding<SchemaDraft.Field>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Field name", text: field.name)
                Picker("Kind", selection: field.kind) {
                    ForEach(FieldKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Toggle("Required", isOn: field.required)
                Toggle("Hidden", isOn: field.hidden)
            }
            if field.wrappedValue.kind == .choice {
                TextField("Values, separated by commas", text: field.valuesText)
            }
        }
    }

    // MARK: - Actions

    private func load() {
        guard let store else {
            errorMessage = "Fen can't reach this folder."
            return
        }
        do {
            let result = try store.load()
            original = result.schema
            draft = SchemaDraft(result.schema)
            hasFile = result.hasFile
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        errorMessage = nil
        guard hasFile else {
            confirmingCreate = true
            return
        }
        var schema = draft.schema
        let diff = SchemaDiff(from: original, to: schema)
        if let version = diff.autoVersion(after: original.version) {
            schema.version = version
            write(schema)
        } else {
            schema.version = original.version.bumpedMajor
            review = Review(
                diff: diff,
                schema: schema,
                renames: SchemaMigration.suggestedRenames(from: original, to: schema)
            )
        }
    }

    private func create() {
        var schema = draft.schema
        schema.version = SchemaVersion(1)
        do {
            try store?.create(schema)
            library.schemaDidChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func write(_ schema: DocumentSchema) {
        do {
            try store?.save(schema, replacing: original)
            library.schemaDidChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish(_ review: Review, renames _: [FieldRename], preview: MigrationPreview) {
        self.review = nil
        do {
            try store?.save(review.schema, replacing: original)
            library.schemaDidChange()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard !preview.impacts.isEmpty else {
            dismiss()
            return
        }
        let result = SchemaMigration.apply(preview, workspaceID: workspace.id, gate: gate)
        resultMessage = "Saved version \(review.schema.version). Updated \(result.applied) documents."
            + (result.failures.isEmpty ? "" : " \(result.failures.count) were not changed: \(result.failures[0])")
    }
}
