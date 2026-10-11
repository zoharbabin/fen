import Observation
import SwiftUI

/// Asks for the Ask panel from outside the Workspaces window, such as the menu command. The window
/// shows the panel when it sees the request.
@MainActor @Observable
public final class AskPanelRequest {
    public static let shared = AskPanelRequest()
    public var isRequested = false
    public init() {}
}

/// "Ask your workspaces" (issue #141): a question, an answer streamed from your index, and the
/// passages it cites. It reads only. Clicking a citation opens the file at that place.
struct AskView: View {
    let library: WorkspaceLibrary
    let service: AIService
    let initialWorkspace: UUID?
    let open: (Passage) -> Void

    @State private var controller: AskController
    @State private var question = ""
    @State private var chosen: Set<UUID>

    init(library: WorkspaceLibrary, service: AIService, initialWorkspace: UUID?, open: @escaping (Passage) -> Void) {
        self.library = library
        self.service = service
        self.initialWorkspace = initialWorkspace
        self.open = open
        _controller = State(initialValue: AskController(library: library, service: service))
        _chosen = State(initialValue: initialWorkspace.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Ask Your Workspaces")
        .onDisappear { controller.cancel() }
    }

    // MARK: - Header

    private var scope: WorkspaceScope {
        let live = chosen.filter { id in library.workspaces.contains { $0.id == id } }
        switch live.count {
        case 0: return .all
        case 1: return .workspace(live.first!)
        default: return .chosen(live)
        }
    }

    private var scopeTitle: String {
        let names = library.workspaces.filter { chosen.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "All workspaces"
        case 1: return names[0]
        default: return "\(names.count) workspaces"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("What did we decide about…?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                if controller.isWorking {
                    Button("Stop") { controller.cancel() }
                } else {
                    Button("Ask", action: ask)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack {
                scopeMenu
                if let notice = service.disclosure {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var scopeMenu: some View {
        Menu {
            Button("All workspaces") { chosen = [] }
            Divider()
            ForEach(library.workspaces) { workspace in
                Toggle(workspace.name, isOn: Binding(
                    get: { chosen.contains(workspace.id) },
                    set: { isOn in
                        if isOn {
                            chosen.insert(workspace.id)
                        } else {
                            chosen.remove(workspace.id)
                        }
                    }
                ))
            }
        } label: {
            Label(scopeTitle, systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which workspaces Fen reads to answer")
    }

    private func ask() {
        controller.ask(question, scope: scope)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            ContentUnavailableView(
                "Ask about your notes",
                systemImage: "text.bubble",
                description: Text(
                    "Fen answers from the files in the workspaces you pick, and shows where each answer comes from."
                )
            )
        case let .failed(reason):
            ContentUnavailableView("Can't answer", systemImage: "exclamationmark.triangle", description: Text(reason))
        case .searching:
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .answering, .done, .notFound:
            answer
        }
    }

    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !controller.skipped.isEmpty {
                    Label(skippedText, systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if controller.phase == .notFound {
                    Text(AskPrompt.notFound).font(.headline)
                } else {
                    Text(controller.linkedAnswer)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { link in
                            guard let passage = controller.passage(for: link) else { return .discarded }
                            open(passage)
                            return .handled
                        })
                    if controller.phase == .answering {
                        ProgressView().controlSize(.small)
                    }
                }
                if controller.hasUnsupportedStatements {
                    Label(
                        "Some statements have no source. Check them before you rely on them.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
                sources
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var skippedText: String {
        let names = controller.skipped.joined(separator: ", ")
        let noun = controller.skipped.count == 1 ? "workspace was" : "workspaces were"
        let count = controller.skipped.count
        return "\(count) \(noun) left out because their AI data access doesn't allow this provider: \(names)."
    }

    @ViewBuilder
    private var sources: some View {
        let cited = controller.citedPassages
        if !cited.isEmpty {
            Divider()
            Text("Sources").font(.headline)
            ForEach(Array(controller.passages.enumerated()), id: \.element.id) { offset, passage in
                if cited.contains(passage) {
                    SourceRow(number: offset + 1, passage: passage) { open(passage) }
                }
            }
        }
    }
}

private struct SourceRow: View {
    let number: Int
    let passage: Passage
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(number)] \(passage.fileName)").font(.body)
                Text(location).font(.caption).foregroundStyle(.secondary)
                Text(passage.text.prefix(200))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the file at this passage")
    }

    private var location: String {
        var parts = [passage.workspaceName, passage.relativePath]
        if !passage.heading.isEmpty {
            parts.append(passage.heading)
        }
        parts.append(passage.lineRange)
        return parts.joined(separator: " · ")
    }
}
