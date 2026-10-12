import SwiftUI

/// Typed controls for the front matter of a document whose `type:` is in the workspace schema
/// (issue #7), under the outline. Each control writes one plain YAML line and leaves the rest of
/// the file alone. It also shows advice about likely typos. The advice never blocks anything.
struct PropertiesSection: View {
    let text: String
    let fileURL: URL?
    let library: WorkspaceLibrary
    /// Receives the whole new document text. The editor applies it as one undoable edit.
    let change: (String) -> Void
    @State private var schema: DocumentSchema?
    @State private var message: String?

    private struct Key: Equatable {
        let url: URL?
        let schemaRevision: Int
        let listingRevision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            if let schema, case let snapshot = PropertiesSnapshot(text: text, schema: schema), snapshot.isRelevant {
                Divider()
                content(snapshot)
            }
        }
        .accessibilityIdentifier("PropertiesSection")
        .task(id: Key(
            url: fileURL, schemaRevision: library.schemaRevision, listingRevision: library.listingRevision
        )) {
            library.start()
            schema = await library.schema(for: fileURL)
        }
    }

    private func content(_ snapshot: PropertiesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.type.map { "Properties · \($0.name)" } ?? "Properties")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(snapshot.hints) { hint in
                hintRow(hint, snapshot)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.rows) { row in
                        PropertyRow(row: row) { input in
                            commit(snapshot, row.field, input)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func hintRow(_ hint: SchemaHint, _ snapshot: PropertiesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(hint.message, systemImage: "lightbulb")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Fix") { apply(hint.fix, snapshot) }
                .font(.caption)
                .help("Changes only this word. Undo takes it back.")
                .accessibilityHint(hint.message)
        }
    }

    private func commit(_ snapshot: PropertiesSnapshot, _ field: SchemaField, _ input: String) {
        do {
            try change(snapshot.setting(input, for: field))
            message = nil
        } catch let error as FrontMatterError where error == .complexExistingValue {
            message = "\(field.name) is a list in the file. Edit it in the text."
        } catch {
            message = "\(field.name): \(error.localizedDescription)"
        }
    }

    private func apply(_ fix: SchemaHint.Fix, _ snapshot: PropertiesSnapshot) {
        do {
            try change(snapshot.applying(fix))
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct PropertyRow: View {
    let row: PropertiesSnapshot.Row
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.field.name + (row.field.required ? " *" : ""))
                .font(.caption.bold())
                .help(row.field.description)
            control
            if row.isMissingRequired {
                Text("Required").font(.caption2).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Property-\(row.field.name)")
        .onAppear { draft = row.value }
        .onChange(of: row.value) { _, new in draft = new }
    }

    @ViewBuilder
    private var control: some View {
        if !row.isEditable {
            Text(row.value).font(.callout).foregroundStyle(.secondary)
        } else {
            switch row.field.kind {
            case .choice: choice
            case .boolean:
                Toggle("", isOn: Binding(get: { row.value == "true" }, set: { commit($0 ? "true" : "false") }))
                    .labelsHidden()
            case .date: date
            case .text, .number, .list: textField
            }
        }
    }

    private var textField: some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    save()
                }
            }
    }

    private var prompt: String {
        row.field.kind == .list ? "a, b, c" : ""
    }

    private func save() {
        if draft != row.value {
            commit(draft)
        }
    }

    private var choice: some View {
        let known = row.field.values
        return Picker("", selection: Binding(get: { row.value }, set: { commit($0) })) {
            Text("None").tag("")
            ForEach(known, id: \.self) { Text($0).tag($0) }
            if !row.value.isEmpty, !known.contains(row.value) {
                Text(row.value).tag(row.value)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var date: some View {
        if let day = DocumentProperties.day(from: row.value) {
            HStack {
                let selection = Binding(get: { day }, set: { commit(DocumentProperties.text(forDay: $0)) })
                DatePicker("", selection: selection, displayedComponents: .date)
                    .labelsHidden()
                Button("Clear", systemImage: "xmark.circle") { commit("") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        } else if row.value.isEmpty {
            Button("Set date") { commit(DocumentProperties.text(forDay: Date())) }
        } else {
            textField
        }
    }
}
