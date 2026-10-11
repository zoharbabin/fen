import Foundation

/// Turns text into vectors for the search index (issues #4, #35). Local only, by design: a
/// workspace is never sent out to be embedded, whatever its AI data access says.
public protocol EmbeddingProvider: Sendable {
    var id: String { get }
    var dimension: Int { get }
    /// `true` when the model runs inside this device's process. Anything else is refused.
    var runsOnDevice: Bool { get }
    func embed(_ text: String) async throws -> [Float]
}

public struct EmbeddingProviderError: Error, LocalizedError, Equatable {
    public let providerID: String

    public var errorDescription: String? {
        "\(providerID) does not run on this device. Embeddings never leave it."
    }
}

/// The embedding providers Fen may use. It refuses any that run off-device.
@MainActor
public final class EmbeddingProviderRegistry {
    public private(set) var providers: [any EmbeddingProvider] = []

    public init() {}

    public func register(_ provider: any EmbeddingProvider) throws {
        guard provider.runsOnDevice else { throw EmbeddingProviderError(providerID: provider.id) }
        providers.removeAll { $0.id == provider.id }
        providers.append(provider)
    }
}
