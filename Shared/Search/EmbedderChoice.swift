import Foundation

/// Which model turns text into vectors for search (issue #35). The choice is read at launch.
/// Changing it rebuilds each workspace index with the new model.
public enum EmbedderChoice: String, CaseIterable, Identifiable, Sendable {
    /// Apple's sentence models. Built in, no setup. One model per language, for the languages the OS covers.
    case apple
    /// EmbeddingGemma served by Ollama on this Mac. Needs `ollama pull embeddinggemma`.
    /// While Ollama isn't running, search uses words only.
    case embeddingGemma

    public static let defaultsKey = "searchEmbedder"

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .apple: "Built in (Apple, several languages)"
        case .embeddingGemma: "EmbeddingGemma (Ollama on this Mac)"
        }
    }

    public static func current(_ defaults: UserDefaults = .standard) -> EmbedderChoice {
        defaults.string(forKey: defaultsKey).flatMap(EmbedderChoice.init(rawValue:)) ?? .apple
    }

    public func makeProvider() -> any EmbeddingProvider {
        switch self {
        case .apple:
            AppleSentenceEmbeddingProvider()
        case .embeddingGemma:
            // The address is a constant loopback URL, so this only fails if the constant is wrong.
            (try? OllamaEmbeddingProvider()) ?? AppleSentenceEmbeddingProvider()
        }
    }
}
