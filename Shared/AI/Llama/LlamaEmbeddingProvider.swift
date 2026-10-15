import Foundation

/// Embeds text with a model you downloaded (issue #234): EmbeddingGemma 2 or Qwen3 Embedding,
/// run by llama.cpp inside Fen's process. Both cover 100+ languages in one shared space, so a
/// query in one language finds notes in another. Nothing leaves the device.
public final class LlamaEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    /// The id names the model, so choosing another one rebuilds the index.
    public let id: String
    public let dimension: Int
    public let runsOnDevice = true
    /// Calibrated per model in docs/spikes/embedding-model.md.
    public let similarityFloor: Float

    private let model: ModelDescriptor
    private let file: URL

    /// `nil` unless `model` is an embedding model.
    public init?(model: ModelDescriptor, file: URL) {
        guard model.role == .embedding, model.embeddingDimension > 0 else { return nil }
        self.model = model
        self.file = file
        id = "llama.\(model.id)"
        dimension = model.embeddingDimension
        similarityFloor = Self.floors[model.kind] ?? 0.3
    }

    /// Cosines from these models, by family. See docs/spikes/embedding-model.md for the sweep.
    static let floors: [ModelKind: Float] = [.embeddingGemma2: 0.6, .qwen3Embedding: 0.3]

    public var isAvailable: Bool {
        #if canImport(llama)
            FileManager.default.fileExists(atPath: file.path)
        #else
            false
        #endif
    }

    /// A stored note: no task line, as the model card says for documents.
    public func embed(_ text: String) async throws -> [Float] {
        try await vector(LlamaPrompts.document(text, kind: model.kind))
    }

    public func embedQueryTagged(_ text: String) async throws -> TaggedVector {
        try await TaggedVector(space: EmbeddingSpace.single, vector: vector(LlamaPrompts.query(text, kind: model.kind)))
    }

    private func vector(_ prompt: String) async throws -> [Float] {
        #if canImport(llama)
            let model = model, file = file, dimension = dimension
            return try await LlamaWork.run {
                let engine = try LlamaEngineCache.shared.engine(for: model, file: file)
                guard engine.dimension == dimension else { throw EmbeddingTextError.noVector }
                return try engine.embed(prompt, appendEndToken: model.kind == .qwen3Embedding)
            }
        #else
            throw EmbeddingTextError.noVector
        #endif
    }
}
