import Foundation

/// The entry point for every AI feature (issue #4). It picks the selected provider, checks each
/// workspace's AI data access through `AIGateway`, and only then lets the request leave.
///
/// With no provider selected, `send` throws and nothing touches the network.
@MainActor
public final class AIService {
    /// The app-wide service: providers from `~/.fen/ai-providers.json`, keys in the keychain, and
    /// the workspaces from `WorkspaceLibrary.shared`.
    public static let shared = AIService(
        store: AIProviderStore.shared,
        workspaces: { WorkspaceLibrary.shared.workspaces }
    )

    public let store: AIProviderStore
    private let workspaces: () -> [Workspace]

    public init(store: AIProviderStore, workspaces: @escaping () -> [Workspace]) {
        self.store = store
        self.workspaces = workspaces
    }

    public var isConfigured: Bool {
        store.selected != nil
    }

    /// The notice to show beside the action that sends content, or `nil` when it stays on this device.
    public var disclosure: String? {
        store.selected?.disclosure
    }

    /// Where the selected provider sends content. Throws when none is set up or its address is bad.
    public func destination() throws -> ModelDestination {
        guard let config = store.selected else { throw AIError.notConfigured }
        guard let destination = config.destination else { throw AIError.invalidEndpoint(config.baseURL) }
        return destination
    }

    public func send(prompt: String, context: [AIContextItem] = []) throws -> AsyncThrowingStream<String, Error> {
        guard let config = store.selected else { throw AIError.notConfigured }
        let provider = try store.makeProvider(for: config)
        try AIGateway.authorize(context: context, destination: provider.destination, workspaces: workspaces())
        return provider.send(prompt: prompt, context: context)
    }

    /// Sends one short prompt with no context and reports whether the provider answered. For the
    /// "Check connection" button in Settings.
    public func check(_ config: AIProviderConfig) async -> Result<Void, AIError> {
        do {
            let provider = try store.makeProvider(for: config)
            for try await _ in provider.send(prompt: "Reply with the single word OK.", context: []) {
                return .success(())
            }
            return .failure(.badResponse)
        } catch let error as AIError {
            return .failure(error)
        } catch {
            return .failure(.systemModelUnavailable(error.localizedDescription))
        }
    }
}
