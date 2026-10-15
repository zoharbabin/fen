import Foundation

/// Which model turns text into vectors for search (issue #35). The choice is read at launch.
/// Changing it rebuilds each workspace index with the new model.
public enum EmbedderChoice: String, CaseIterable, Identifiable, Sendable {
    /// Apple's sentence models. Built in, no setup. One model per language, for the languages the OS covers.
    case apple
    /// EmbeddingGemma served by Ollama on this Mac. Needs `ollama pull embeddinggemma`.
    /// While Ollama isn't running, search uses words only.
    case embeddingGemma
    /// EmbeddingGemma 2, downloaded in Settings and run inside Fen. 100+ languages in one space.
    case downloadedEmbeddingGemma = "download.embeddinggemma-2-q8"
    /// Qwen3 Embedding 0.6B, downloaded in Settings and run inside Fen.
    case downloadedQwen3 = "download.qwen3-embedding-0.6b-q8"

    public static let defaultsKey = "searchEmbedder"

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .apple: "Built in (Apple, several languages)"
        case .embeddingGemma: "EmbeddingGemma (Ollama on this Mac)"
        case .downloadedEmbeddingGemma, .downloadedQwen3: model?.displayName ?? rawValue
        }
    }

    /// The downloaded model behind this choice, if it is one.
    public var model: ModelDescriptor? {
        switch self {
        case .downloadedEmbeddingGemma: ModelCatalog.embeddingGemma2
        case .downloadedQwen3: ModelCatalog.qwen3Embedding
        case .apple, .embeddingGemma: nil
        }
    }

    /// What the Search picker lists: the built-in ones, and a downloaded model once it is installed.
    public static func offered(home: FenHome = .standard) -> [EmbedderChoice] {
        let store = ModelStore(home: home)
        return allCases.filter { choice in choice.model.map(store.isInstalled) ?? true }
    }

    public static func current(_ defaults: UserDefaults = .standard) -> EmbedderChoice {
        defaults.string(forKey: defaultsKey).flatMap(EmbedderChoice.init(rawValue:)) ?? .apple
    }

    /// A downloaded model whose file is gone gives the built-in model, so search keeps working.
    public func makeProvider(home: FenHome = .standard) -> any EmbeddingProvider {
        switch self {
        case .downloadedEmbeddingGemma, .downloadedQwen3:
            let store = ModelStore(home: home)
            if let model, store.isInstalled(model), let file = try? store.fileURL(for: model),
               let provider = LlamaEmbeddingProvider(model: model, file: file) {
                return provider
            }
            return AppleSentenceEmbeddingProvider()
        case .apple:
            return AppleSentenceEmbeddingProvider()
        case .embeddingGemma:
            // The address is a constant loopback URL, so this only fails if the constant is wrong.
            if let provider = try? OllamaEmbeddingProvider() {
                return provider
            }
            return AppleSentenceEmbeddingProvider()
        }
    }
}
