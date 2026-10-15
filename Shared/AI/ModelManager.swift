import Foundation
import Observation

/// What Settings shows for each downloadable model, and the downloads behind it (issue #234).
/// A download starts only from `download(_:)`, which the UI calls after you confirmed the host
/// and size in `ModelDescriptor.consentText`.
@MainActor @Observable
public final class ModelManager {
    public static let shared = ModelManager(home: .standard)

    public enum State: Equatable, Sendable {
        /// `partial` bytes are kept from an earlier try, and the next download continues from them.
        case notInstalled(partial: Int64)
        case downloading(received: Int64)
        case installed
        case failed(String)
    }

    /// The models this device may run.
    public let models: [ModelDescriptor]
    public private(set) var states: [String: State] = [:]
    /// iOS only: allow a download over cellular data or a personal hotspot. Off by default.
    public var allowsCellular = false

    @ObservationIgnored private let home: FenHome
    @ObservationIgnored private let customStore: ModelStore?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    public init(home: FenHome, catalog: [ModelDescriptor] = ModelCatalog.all) {
        self.home = home
        customStore = nil
        models = catalog.filter { $0.platforms.contains(.current) }
        refresh()
    }

    /// For tests: a store with its own session.
    init(home: FenHome, store: ModelStore, catalog: [ModelDescriptor]) {
        self.home = home
        customStore = store
        models = catalog
        refresh()
    }

    private var store: ModelStore {
        if let customStore {
            return customStore
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        return ModelStore(home: home, session: ModelStore.makeSession(configuration: configuration))
    }

    public func state(for model: ModelDescriptor) -> State {
        states[model.id] ?? .notInstalled(partial: 0)
    }

    /// Why this device can't run `model`, or `nil`.
    public func unavailableReason(for model: ModelDescriptor) -> String? {
        do {
            try ModelStore.checkDevice(for: model)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Reads the disk again. Models being downloaded keep their state.
    public func refresh() {
        let store = ModelStore(home: home)
        for model in models where tasks[model.id] == nil {
            if case .failed = states[model.id] {
                continue
            }
            states[model.id] = store.isInstalled(model)
                ? .installed
                : .notInstalled(partial: store.partialBytes(model))
        }
    }

    public func isInstalled(_ model: ModelDescriptor) -> Bool {
        state(for: model) == .installed
    }

    // MARK: - Download

    /// Starts the download. Call it only after you showed `model.consentText` and got a yes.
    public func download(_ model: ModelDescriptor) {
        guard tasks[model.id] == nil, !isInstalled(model) else { return }
        let store = store
        states[model.id] = .downloading(received: store.partialBytes(model))
        tasks[model.id] = Task { [weak self] in
            let last = LastReported()
            do {
                try await store.download(model, confirmedHost: model.host, confirmedBytes: model.byteCount) { bytes in
                    // Report about every 512 KB, so a fast download doesn't flood the main actor.
                    guard last.advance(to: bytes, by: 512 * 1024) else { return }
                    Task { @MainActor in self?.report(model, received: bytes) }
                }
                self?.finish(model, .installed)
            } catch is CancellationError {
                self?.finish(model, nil)
            } catch {
                self?.finish(model, .failed(error.localizedDescription))
            }
        }
    }

    /// Stops the download and keeps the part that arrived.
    public func cancel(_ model: ModelDescriptor) {
        tasks[model.id]?.cancel()
    }

    /// Deletes the model and any part of it. A download in progress is stopped first.
    public func delete(_ model: ModelDescriptor) throws {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        try ModelStore(home: home).remove(model)
        states[model.id] = .notInstalled(partial: 0)
    }

    private func report(_ model: ModelDescriptor, received: Int64) {
        guard tasks[model.id] != nil else { return }
        states[model.id] = .downloading(received: received)
    }

    private func finish(_ model: ModelDescriptor, _ result: State?) {
        tasks[model.id] = nil
        if let result {
            states[model.id] = result
        } else {
            states[model.id] = .notInstalled(partial: ModelStore(home: home).partialBytes(model))
        }
    }

    // MARK: - Choosing

    /// The search models to list: the built-in ones, and each downloaded one that is installed.
    public func offeredEmbedders() -> [EmbedderChoice] {
        EmbedderChoice.allCases.filter { choice in choice.model.map(isInstalled) ?? true }
    }

    /// Adds a provider for `model` if there is none, and selects it for Ask and Enrich.
    public func useForAnswers(_ model: ModelDescriptor, in providers: AIProviderStore) throws {
        if let existing = providers.providers.first(where: { $0.kind == .downloaded && $0.model == model.id }) {
            try providers.select(id: existing.id)
        } else {
            let config = AIProviderConfig(name: model.displayName, kind: .downloaded, model: model.id)
            try providers.add(config)
            try providers.select(id: config.id)
        }
    }

    public func isUsedForAnswers(_ model: ModelDescriptor, in providers: AIProviderStore) -> Bool {
        providers.selected.map { $0.kind == .downloaded && $0.model == model.id } ?? false
    }
}

/// Lets a progress callback that runs on any thread skip reports that are too close together.
private final class LastReported: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func advance(to bytes: Int64, by step: Int64) -> Bool {
        lock.withLock {
            guard bytes - value >= step else { return false }
            value = bytes
            return true
        }
    }
}
