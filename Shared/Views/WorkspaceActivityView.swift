import SwiftUI

/// Changes AI made or wants to make in one workspace (issue #140): approve or reject waiting ones,
/// see what was applied and why, and undo one change or a whole run.
struct WorkspaceActivityView: View {
    let gate: WriteGate
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            let waiting = gate.pending(for: workspace.id)
            let applied = gate.entries(for: workspace.id).reversed().map(\.self)
            List {
                if gate.isPaused {
                    Label("Auto-approve is paused. Every change asks first.", systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }
                if !waiting.isEmpty {
                    Section("Waiting for you") {
                        ForEach(waiting) { item in
                            PendingRow(item: item, approve: { approve(item) }, reject: { gate.reject(item.id) })
                        }
                    }
                }
                Section("Applied") {
                    if applied.isEmpty {
                        Text("No AI changes yet.").foregroundStyle(.secondary)
                    }
                    ForEach(applied) { entry in
                        EntryRow(entry: entry, undo: { undo(entry) }, revertRun: { revert(entry) })
                    }
                }
            }
            .navigationTitle("\(workspace.name) Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Activity", isPresented: Binding(get: { message != nil }, set: {
                if !$0 {
                    message = nil
                }
            })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }

    private func approve(_ item: WriteGate.Pending) {
        do {
            try gate.approve(item.id)
        } catch {
            message = error.localizedDescription
        }
    }

    private func undo(_ entry: ActivityEntry) {
        do {
            try gate.undo(entry.id, workspaceID: workspace.id)
        } catch {
            message = error.localizedDescription
        }
    }

    private func revert(_ entry: ActivityEntry) {
        let result = gate.revertRun(entry.runID, workspaceID: workspace.id)
        message = result.failures.isEmpty
            ? "Undid \(result.undone) change\(result.undone == 1 ? "" : "s")."
            : "Undid \(result.undone). Left alone:\n" + result.failures.joined(separator: "\n")
    }
}

private struct PendingRow: View {
    let item: WriteGate.Pending
    let approve: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.change.edit.paths.joined(separator: " → ")).font(.headline)
                Spacer()
                Text(item.change.edit.name).font(.caption).foregroundStyle(.secondary)
            }
            Text(reasonText).font(.caption).foregroundStyle(.secondary)
            DiffText(diff: item.diff)
            HStack {
                Button("Approve", action: approve).buttonStyle(.borderedProminent)
                Button("Reject", role: .cancel, action: reject)
            }
        }
        .padding(.vertical, 4)
    }

    private var reasonText: String {
        switch item.reason {
        case .modeIsAsk: "This workspace asks before AI changes a file."
        case .destructive: "Deleting, moving, or replacing a whole file always asks."
        case .replacingNotOptedIn: "Auto-approve isn't on for replacing text in this operation."
        case .paused: "Auto-approve is paused."
        case .overCap: "This run changed more than the limits in the workspace settings."
        }
    }
}

private struct EntryRow: View {
    let entry: ActivityEntry
    let undo: () -> Void
    let revertRun: () -> Void

    var body: some View {
        DisclosureGroup {
            DiffText(diff: entry.diff)
            Text("\(entry.provenance.provider) \(entry.provenance.model) · \(approvedText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !entry.provenance.sources.isEmpty {
                Text("From: " + entry.provenance.sources.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.toPath.map { "\(entry.path) → \($0)" } ?? entry.path)
                        .strikethrough(entry.isUndone)
                    Text("\(entry.edit) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.isUndone {
                    Text("Undone").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Undo", action: undo)
                }
            }
        }
        .contextMenu {
            Button("Undo This Change", action: undo).disabled(entry.isUndone)
            Button("Revert This Run", action: revertRun)
        }
    }

    private var approvedText: String {
        switch entry.approvedBy {
        case .auto: "auto-approved"
        case .user: "approved by you"
        case .invoked: "started by you"
        }
    }
}

private struct DiffText: View {
    let diff: LineDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                Text(prefix(line) + line.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(color(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(diff.added) lines added, \(diff.removed) removed")
    }

    private func prefix(_ line: LineDiff.Line) -> String {
        switch line.kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        case .gap: "…"
        }
    }

    private func color(_ line: LineDiff.Line) -> Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        case .context, .gap: .secondary
        }
    }
}
