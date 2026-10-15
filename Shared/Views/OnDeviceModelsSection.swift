import SwiftUI

/// Settings > AI > On-device models (issue #234). Download a model, and choose which one Search
/// and Answers use. A download starts only after you confirm the host and size.
struct OnDeviceModelsSection: View {
    @Bindable var manager: ModelManager
    let providers: AIProviderStore
    @Binding var embedder: String
    @State private var confirming: ModelDescriptor?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(manager.models) { model in
                row(model)
            }
            #if os(iOS)
                Toggle("Allow cellular data", isOn: $manager.allowsCellular)
            #endif
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        } header: {
            Text("On-device models")
        } footer: {
            Text(
                "Models run on this device and send nothing out. Fen downloads one only after you confirm, "
                    + "straight from huggingface.co, and checks its size and SHA-256. "
                    + "Search and Ask work without a network once a model is here."
            )
        }
        .onAppear { manager.refresh() }
        .confirmationDialog(
            confirming.map { "Download \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: {
                if !$0 {
                    confirming = nil
                }
            }),
            titleVisibility: .visible,
            presenting: confirming
        ) { model in
            Button("Download") { manager.download(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(model.consentText)
        }
    }

    private func row(_ model: ModelDescriptor) -> some View {
        let state = manager.state(for: model)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                    Text(details(model)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions(model, state)
            }
            if case let .downloading(received) = state {
                ProgressView(value: Double(received), total: Double(model.byteCount))
                Text(progressText(received, of: model.byteCount)).font(.caption).foregroundStyle(.secondary)
            }
            if case let .notInstalled(partial) = state, partial > 0 {
                Text("\(format(partial)) already downloaded. Download continues from there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case let .failed(message) = state {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            if let reason = manager.unavailableReason(for: model), state != .installed {
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func actions(_ model: ModelDescriptor, _ state: ModelManager.State) -> some View {
        switch state {
        case .downloading:
            Button("Cancel") { manager.cancel(model) }
        case .installed:
            use(model)
            Button("Delete", role: .destructive) {
                run {
                    try manager.delete(model)
                    // Search falls back to the built-in model, so the picker should say so.
                    if EmbedderChoice(rawValue: embedder)?.model?.id == model
                        .id {
                        embedder = EmbedderChoice.apple.rawValue
                    }
                }
            }
        case .notInstalled, .failed:
            if case let .notInstalled(partial) = state, partial > 0 {
                Button("Delete part", role: .destructive) { run { try manager.delete(model) } }
            }
            Button("Download") { confirming = model }
                .disabled(manager.unavailableReason(for: model) != nil)
        }
    }

    @ViewBuilder
    private func use(_ model: ModelDescriptor) -> some View {
        switch model.role {
        case .embedding:
            let choice = EmbedderChoice.allCases.first { $0.model?.id == model.id }
            if let choice {
                if embedder == choice.rawValue {
                    Label("Used for Search", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Button("Use for Search") { embedder = choice.rawValue }
                }
            }
        case .answer:
            if manager.isUsedForAnswers(model, in: providers) {
                Label("Used for Answers", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Button("Use for Answers") { run { try manager.useForAnswers(model, in: providers) } }
            }
        }
    }

    private func details(_ model: ModelDescriptor) -> String {
        [model.role.title, format(model.byteCount), model.licenseName, model.languages]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func progressText(_ received: Int64, of total: Int64) -> String {
        "\(format(received)) of \(format(total))"
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
