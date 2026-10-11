import SwiftUI

/// Notes that now disagree (issue #94). Check what changed since the last run, read each possible
/// conflict side by side, and propose a fix. A fix goes through the write gate, so it waits in
/// Activity unless you opted `resolve-conflict` into auto-approve.
struct ConflictsView: View {
    let library: WorkspaceLibrary
    let gate: WriteGate
    let workspace: Workspace
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var flags: [ConflictFlag] = []
    @State private var task: Task<Void, Never>?
    @State private var progress: String?
    @State private var message: String?

    private var resolver: ConflictResolver {
        ConflictResolver(library: library, service: .shared, gate: gate)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    controls
                } footer: {
                    Text(
                        "Fen compares what changed since the last check with the notes near it. Nothing is written until you approve a fix."
                    )
                }
                if flags.isEmpty {
                    Section {
                        Text("No possible conflicts.").foregroundStyle(.secondary)
                    }
                }
                ForEach(flags.filter { resolver.status(of: $0, in: workspace.id) != .dismissed }) { flag in
                    FlagRow(
                        flag: flag,
                        status: resolver.status(of: flag, in: workspace.id),
                        open: open,
                        propose: { keep, scope in propose(flag, keep, scope) },
                        dismiss: { act { try resolver.dismiss(flag.id, in: workspace.id) } },
                        revert: { revert(flag) },
                        clear: { act { try resolver.clear(flag.id, in: workspace.id) } }
                    )
                }
                let dismissed = flags.filter { resolver.status(of: $0, in: workspace.id) == .dismissed }
                if !dismissed.isEmpty {
                    Section("Dismissed") {
                        ForEach(dismissed) { flag in
                            HStack {
                                Text("\(flag.changed.path) and \(flag.other.path)").lineLimit(1)
                                Spacer()
                                Button("Reopen") { act { try resolver.reopen(flag.id, in: workspace.id) } }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(workspace.name) Conflicts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Conflicts", isPresented: Binding(get: { message != nil }, set: {
                if !$0 {
                    message = nil
                }
            })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .onAppear(perform: reload)
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private var controls: some View {
        if let progress {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { task?.cancel() }
            }
        } else {
            Button("Check for Conflicts", systemImage: "exclamationmark.arrow.triangle.2.circlepath", action: check)
        }
    }

    private func reload() {
        flags = ConflictStore(file: gate.home.conflictsFile(id: workspace.id)).load().flags
    }

    private func act(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    private func check() {
        guard task == nil else { return }
        progress = "Reading notes…"
        task = Task {
            defer {
                task = nil
                progress = nil
                reload()
            }
            let run = ConflictRun(library: library, service: .shared, gate: gate)
            do {
                let summary = try await run.run(workspaceID: workspace.id) { done, total in
                    progress = "Checking \(done) of \(total)"
                }
                message = summary.text
            } catch is CancellationError {
                message = "Stopped. The next check starts from the same point."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func propose(_ flag: ConflictFlag, _ keep: ConflictKeep, _ scope: ConflictScope) {
        Task {
            defer { reload() }
            do {
                switch try await resolver.resolve(flag, workspaceID: workspace.id, keep: keep, scope: scope) {
                case .queued: message = "Review the fix in Activity. Nothing was written yet."
                case .applied: message = "The fix is on the \(ConflictResolver.agent) branch. You can undo it here or in Activity."
                case let .nothing(why): message = why
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func revert(_ flag: ConflictFlag) {
        Task {
            defer { reload() }
            do {
                try await resolver.revert(flag, in: workspace.id)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct FlagRow: View {
    let flag: ConflictFlag
    let status: ConflictStatus
    let open: (String) -> Void
    let propose: (ConflictKeep, ConflictScope) -> Void
    let dismiss: () -> Void
    let revert: () -> Void
    let clear: () -> Void

    private var confidenceText: String {
        switch flag.confidence {
        case 0.8...: "High"
        case 0.5...: "Medium"
        default: "Low"
        }
    }

    var body: some View {
        Section {
            HStack {
                Text("\(confidenceText) confidence")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Text(flag.explanation).font(.callout)
            }
            side("Edited note", flag.changed, isStale: flag.staleSide == "changed" || flag.staleSide == "both")
            side("Other note", flag.other, isStale: flag.staleSide == "other" || flag.staleSide == "both")
            actions
        }
    }

    private func side(_ title: String, _ side: ConflictSide, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if isStale {
                    Text("probably out of date").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Open \(side.path)") { open(side.path) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Text(side.text).font(.callout).lineLimit(5).textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack {
            switch status {
            case .open:
                Menu("Propose Fix") {
                    ForEach([ConflictKeep.changed, .other], id: \.self) { keep in
                        let kept = keep == .changed ? flag.changed.path : flag.other.path
                        let target = keep == .changed ? flag.other.path : flag.changed.path
                        Menu("Keep \(kept)") {
                            ForEach(ConflictScope.allCases) { scope in
                                Button("Rewrite \(scope == .passage ? "the passage" : "all") in \(target)") {
                                    propose(keep, scope)
                                }
                            }
                        }
                    }
                }
                Button("Dismiss", action: dismiss)
            case .waiting:
                Label("A fix waits in Activity", systemImage: "clock").foregroundStyle(.secondary)
            case .resolved:
                Label("Fixed", systemImage: "checkmark.circle").foregroundStyle(.green)
                Button("Undo Fix", action: revert)
                Button("Clear", action: clear)
            case .dismissed:
                EmptyView()
            }
        }
    }
}
