import Foundation

/// One vector space: vectors that can be compared with each other (issue #234). A model with one
/// space uses the empty tag. Apple's sentence models have one space per language, because each
/// language is its own model with its own sizes.
public struct EmbeddingSpace: Hashable, Sendable {
    public static let single = ""

    public let tag: String
    public let dimension: Int

    public init(tag: String, dimension: Int) {
        self.tag = tag
        self.dimension = dimension
    }
}

/// A vector and the space it lives in. Only vectors of the same space may be compared.
public struct TaggedVector: Sendable, Equatable {
    public let space: String
    public let vector: [Float]

    public init(space: String, vector: [Float]) {
        self.space = space
        self.vector = vector
    }
}

/// Turns text into vectors for the search index (issues #4, #35). Local only, by design: a
/// workspace is never sent out to be embedded, whatever its AI data access says.
public protocol EmbeddingProvider: Sendable {
    var id: String { get }
    /// The size of the default space. `embed` returns vectors of this size.
    var dimension: Int { get }
    /// `true` when the model runs inside this device's process. Anything else is refused.
    var runsOnDevice: Bool { get }
    /// `false` when the model can't load here, for example if its assets are missing. The index
    /// then uses words only.
    var isAvailable: Bool { get }
    /// Matches with a cosine below this are noise for this model, so they are dropped.
    var similarityFloor: Float { get }
    /// Every space this model can fill right now. Asked once per index, off the main actor.
    var spaces: [EmbeddingSpace] { get }
    /// The vector of `text` in the default space, or throws `EmbeddingTextError` when the model
    /// can't read it. Used where vectors of different texts must be comparable.
    func embed(_ text: String) async throws -> [Float]
    /// The vector of `text` in the space that fits it best (for example its language).
    func embedTagged(_ text: String) async throws -> TaggedVector
    /// Like `embedTagged`, for a search query. Some models read a question differently from a note.
    func embedQueryTagged(_ text: String) async throws -> TaggedVector
    /// `similarityFloor` for one space. Models of different languages have different score ranges.
    func similarityFloor(inSpace space: String) -> Float
}

public extension EmbeddingProvider {
    var isAvailable: Bool {
        true
    }

    var similarityFloor: Float {
        0
    }

    var spaces: [EmbeddingSpace] {
        [EmbeddingSpace(tag: EmbeddingSpace.single, dimension: dimension)]
    }

    func embedTagged(_ text: String) async throws -> TaggedVector {
        try await TaggedVector(space: EmbeddingSpace.single, vector: embed(text))
    }

    func embedQueryTagged(_ text: String) async throws -> TaggedVector {
        try await embedTagged(text)
    }

    func similarityFloor(inSpace _: String) -> Float {
        similarityFloor
    }
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
