import Foundation
import Observation

/// One provider the user set up (issue #4). The API key is not here: it lives in the keychain.
public struct AIProviderConfig: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var kind: ProviderKind
    /// Empty for the on-device model and for downloaded models.
    public var baseURL: String
    /// Empty for the on-device model. For a downloaded model, its id in `ModelCatalog`.
    public var model: String

    public init(id: UUID = UUID(), name: String, kind: ProviderKind, baseURL: String = "", model: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
    }

    /// Runs inside Fen's process, so it has no address.
    private var runsInProcess: Bool {
        kind == .onDevice || kind == .downloaded
    }

    /// The address as Fen would use it, or `nil` for in-process models and for a bad address.
    public var endpoint: AIEndpoint? {
        runsInProcess ? nil : try? AIEndpoint(baseURL)
    }

    /// Where content goes. `nil` while the address is invalid.
    public var destination: ModelDestination? {
        runsInProcess ? .local : endpoint?.destination
    }

    /// The notice to show where an action sends content, or `nil` when content stays on this device.
    public var disclosure: String? {
        guard let endpoint, !endpoint.isLoopback else { return nil }
        return "This sends content to \(endpoint.host)."
    }
}

/// The saved providers and which one is selected, kept in `~/.fen/ai-providers.json`. Keys go to a
/// `SecretStore`. Nothing is written until you add a provider, and with none added, no AI feature
/// runs and no AI request is made.
@MainActor @Observable
public final class AIProviderStore {
    public static let shared: AIProviderStore = {
        let store = AIProviderStore(home: .standard)
        try? store.load()
        return store
    }()

    public private(set) var providers: [AIProviderConfig] = []
    public private(set) var selectedID: UUID?

    private let home: FenHome
    private let secrets: any SecretStore
    private let session: URLSession

    private struct FileFormat: Codable {
        var version = 1
        var selectedID: UUID?
        var providers: [AIProviderConfig]
    }

    public init(home: FenHome, secrets: any SecretStore = KeychainSecretStore()) {
        self.home = home
        self.secrets = secrets
        session = AIHTTP.makeSession()
    }

    init(home: FenHome, secrets: any SecretStore, session: URLSession) {
        self.home = home
        self.secrets = secrets
        self.session = session
    }

    public var selected: AIProviderConfig? {
        providers.first { $0.id == selectedID }
    }

    /// A missing file means no providers. A corrupt file throws and is left in place.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: home.aiProvidersFile.path) else {
            providers = []
            selectedID = nil
            return
        }
        let file = try JSONDecoder().decode(FileFormat.self, from: Data(contentsOf: home.aiProvidersFile))
        providers = file.providers
        selectedID = file.providers.contains { $0.id == file.selectedID } ? file.selectedID : file.providers.first?.id
    }

    // MARK: - Editing

    /// Throws why `config` can't work. Called before every save.
    public func validate(_ config: AIProviderConfig) throws {
        switch config.kind {
        case .onDevice:
            return
        case .downloaded:
            guard ModelCatalog.model(id: config.model)?.role == .answer else { throw AIError.missingModel }
            return
        case .ollama:
            let endpoint = try AIEndpoint(config.baseURL)
            guard endpoint.isLoopback else { throw AIError.notLoopback(host: endpoint.host) }
        case .openAICompatible:
            _ = try AIEndpoint(config.baseURL)
        }
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AIError.missingModel
        }
    }

    /// Adds a provider and selects it if it is the first. A key is stored only when given.
    public func add(_ config: AIProviderConfig, apiKey: String? = nil) throws {
        try validate(config)
        if let apiKey, !apiKey.isEmpty {
            try secrets.write(apiKey, account: config.id.uuidString)
        }
        providers.append(config)
        if selectedID == nil {
            selectedID = config.id
        }
        try save()
    }

    /// Replaces a provider. `apiKey` `nil` keeps the stored key. An empty string removes it.
    public func update(_ config: AIProviderConfig, apiKey: String? = nil) throws {
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else { return }
        try validate(config)
        if let apiKey {
            if apiKey.isEmpty {
                try secrets.delete(account: config.id.uuidString)
            } else {
                try secrets.write(apiKey, account: config.id.uuidString)
            }
        }
        providers[index] = config
        try save()
    }

    public func remove(id: UUID) throws {
        try secrets.delete(account: id.uuidString)
        providers.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = providers.first?.id
        }
        try save()
    }

    public func select(id: UUID) throws {
        guard providers.contains(where: { $0.id == id }) else { return }
        selectedID = id
        try save()
    }

    public func hasAPIKey(for id: UUID) -> Bool {
        ((try? secrets.read(account: id.uuidString)) ?? nil) != nil
    }

    private func save() throws {
        try home.ensureExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(selectedID: selectedID, providers: providers))
        try data.write(to: home.aiProvidersFile, options: .atomic)
    }

    // MARK: - Providers

    /// The live provider for `config`. Reads the key from the secret store.
    func makeProvider(for config: AIProviderConfig) throws -> any AIProvider {
        try validate(config)
        switch config.kind {
        case .onDevice:
            return OnDeviceProvider()
        case .downloaded:
            let store = ModelStore(home: home)
            guard let model = ModelCatalog.model(id: config.model) else { throw AIError.missingModel }
            guard store.isInstalled(model) else { throw AIError.modelNotInstalled(model.displayName) }
            return try LlamaAnswerProvider(model: model, file: store.fileURL(for: model))
        case .ollama:
            return try OllamaProvider(endpoint: AIEndpoint(config.baseURL), model: config.model, session: session)
        case .openAICompatible:
            return try OpenAICompatibleProvider(
                endpoint: AIEndpoint(config.baseURL),
                model: config.model,
                apiKey: secrets.read(account: config.id.uuidString),
                session: session
            )
        }
    }
}
