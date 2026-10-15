import SwiftUI

/// Set up the AI providers Fen can use (issue #4). With none added, no AI feature runs and Fen
/// makes no AI request.
struct AISettingsTab: View {
    private let service: AIService
    @State private var editing: ProviderDraft?
    @State private var checks: [UUID: String] = [:]
    @State private var errorMessage: String?
    @Bindable private var preferences = Preferences.shared
    @AppStorage(EmbedderChoice.defaultsKey) private var embedder = EmbedderChoice.apple.rawValue
    @State private var models = ModelManager.shared

    init(service: AIService = .shared) {
        self.service = service
    }

    private var store: AIProviderStore {
        service.store
    }

    var body: some View {
        Form {
            Section {
                if store.providers.isEmpty {
                    Text("No provider yet. Fen's AI features stay off, and nothing leaves this device.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.providers) { provider in
                    row(provider)
                }
                Menu("Add provider", systemImage: "plus") {
                    ForEach(ProviderKind.allCases.filter { $0 != .downloaded }, id: \.self) { kind in
                        Button(kind.title) { editing = ProviderDraft(kind: kind) }
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Each workspace decides which providers may see its files. See the workspace's settings.")
            }
            Section {
                Toggle("Preview before applying", isOn: $preferences.inlineAIPreviewFirst)
            } header: {
                Text("Ask AI and Enrich")
            } footer: {
                Text("Show the result and wait for your click before it changes the document. Undo works either way.")
            }
            OnDeviceModelsSection(manager: models, providers: store, embedder: $embedder)
            Section {
                Picker("Search model", selection: $embedder) {
                    ForEach(models.offeredEmbedders()) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Search")
            } footer: {
                Text(
                    "Matches by meaning. They run on this device and send nothing out. "
                        + "Ollama's EmbeddingGemma needs Ollama running with `embeddinggemma`. Without it, search uses words only. "
                        + "A model you download above covers 100+ languages and finds notes across them. "
                        + "Applies after you restart Fen, and re-indexes your workspaces."
                )
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            ProviderEditor(draft: draft, store: store) { editing = nil }
        }
        #if os(macOS)
        .padding()
        #else
        .navigationTitle("AI")
        #endif
    }

    private func row(_ provider: AIProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: store.selectedID == provider.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.selectedID == provider.id ? Color.accentColor : .secondary)
                    .onTapGesture { run { try store.select(id: provider.id) } }
                    .accessibilityLabel(store.selectedID == provider.id ? "Selected" : "Select")
                    .accessibilityAddTraits(.isButton)
                VStack(alignment: .leading) {
                    Text(provider.name)
                    Text(subtitle(provider)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check") { check(provider) }
                Button("Edit") { editing = ProviderDraft(provider, hasKey: store.hasAPIKey(for: provider.id)) }
                Button("Remove", role: .destructive) { run { try store.remove(id: provider.id) } }
            }
            if let disclosure = provider.disclosure {
                Label(disclosure, systemImage: "network").font(.caption).foregroundStyle(.orange)
            }
            if let result = checks[provider.id] {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ provider: AIProviderConfig) -> String {
        switch provider.kind {
        case .onDevice: provider.kind.title
        case .downloaded: ModelCatalog.model(id: provider.model)?.displayName ?? provider.kind.title
        default: "\(provider.kind.title), \(provider.model)"
        }
    }

    private func check(_ provider: AIProviderConfig) {
        checks[provider.id] = "Checking..."
        Task {
            switch await service.check(provider) {
            case .success: checks[provider.id] = "Connected."
            case let .failure(error): checks[provider.id] = error.localizedDescription
            }
        }
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

struct ProviderDraft: Identifiable {
    let id = UUID()
    var config: AIProviderConfig
    var isNew: Bool
    var hasKey: Bool

    init(kind: ProviderKind) {
        let defaults: (name: String, url: String) = switch kind {
        case .onDevice: ("On-device model", "")
        case .downloaded: ("Downloaded model", "")
        case .ollama: ("Ollama", "http://localhost:11434")
        case .openAICompatible: ("", "http://localhost:1234/v1")
        }
        config = AIProviderConfig(name: defaults.name, kind: kind, baseURL: defaults.url)
        isNew = true
        hasKey = false
    }

    init(_ config: AIProviderConfig, hasKey: Bool) {
        self.config = config
        isNew = false
        self.hasKey = hasKey
    }
}

private struct ProviderEditor: View {
    @State var draft: ProviderDraft
    let store: AIProviderStore
    let close: () -> Void
    @State private var apiKey = ""
    @State private var clearKey = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft.config.name)
                if draft.config.kind == .onDevice {
                    Text(onDeviceStatus).foregroundStyle(.secondary)
                } else {
                    TextField("Address", text: $draft.config.baseURL)
                        .autocorrectionDisabled()
                    TextField("Model", text: $draft.config.model)
                        .autocorrectionDisabled()
                    if draft.config.kind == .openAICompatible {
                        SecureField(
                            draft.hasKey ? "API key (saved, leave blank to keep)" : "API key (optional)",
                            text: $apiKey
                        )
                        if draft.hasKey {
                            Toggle("Remove the saved key", isOn: $clearKey)
                        }
                    }
                }
                if let disclosure = draft.config.disclosure {
                    Label(disclosure, systemImage: "network").foregroundStyle(.orange)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isNew ? "Add provider" : "Edit provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private var onDeviceStatus: String {
        switch OnDeviceModelAvailability.current {
        case .available: "Runs on this device. Nothing is sent anywhere."
        case let .unavailable(reason): reason
        }
    }

    private func save() {
        do {
            let key: String? = clearKey ? "" : (apiKey.isEmpty ? nil : apiKey)
            if draft.isNew {
                try store.add(draft.config, apiKey: key)
            } else {
                try store.update(draft.config, apiKey: key)
            }
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
