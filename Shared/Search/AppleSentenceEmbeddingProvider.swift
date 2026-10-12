import Foundation
import NaturalLanguage

/// The sentence embedding that ships with the OS (Apple's NaturalLanguage), for the search index
/// (issues #35, #4). It runs inside Fen's process, needs no download, and sends nothing out.
///
/// It covers English. Text in another language gets no vector, so it is still found by words.
/// The model loads on first use, not at launch.
public final class AppleSentenceEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public static let identifier = "apple.nl.sentence.en"
    public static let vectorSize = 512

    public let id = AppleSentenceEmbeddingProvider.identifier
    public let dimension = AppleSentenceEmbeddingProvider.vectorSize
    public let runsOnDevice = true
    /// Cosines from this model run low: right answers have a median near 0.29 and wrong ones near
    /// 0.11 (docs/spikes/embedding-model.md). This floor keeps weak matches out of the list.
    public let similarityFloor: Float = 0.15

    private let lock = NSLock()
    private var loaded = false
    private var embedding: NLEmbedding?

    public init() {}

    public var isAvailable: Bool {
        lock.withLock { model() }?.dimension == dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        guard looksEnglish(text) else { throw EmbeddingTextError.unsupportedLanguage }
        let vector: [Double]? = lock.withLock { model()?.vector(for: text) }
        guard let vector, vector.count == dimension else { throw EmbeddingTextError.noVector }
        return vector.map { Float($0) }
    }

    /// Call with `lock` held.
    private func model() -> NLEmbedding? {
        if !loaded {
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
            loaded = true
        }
        return embedding
    }

    private func looksEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first else { return true }
        return top.key == .english || top.value < 0.7
    }
}

/// Why one piece of text got no vector. The search index treats it as "find by words only".
public enum EmbeddingTextError: Error, LocalizedError {
    case unsupportedLanguage
    case noVector

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: "The text isn't in a language this model covers."
        case .noVector: "The model returned no vector for this text."
        }
    }
}
