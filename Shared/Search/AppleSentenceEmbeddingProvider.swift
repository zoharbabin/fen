import Foundation
import NaturalLanguage

/// The sentence embeddings that ship with the OS (Apple's NaturalLanguage), for the search index
/// (issues #35, #4, #234). They run inside Fen's process, need no download, and send nothing out.
///
/// Each language is its own model with its own vector space, so a vector is tagged with its
/// language and only compared with vectors of the same language. The OS decides which languages
/// have a model: Fen asks at run time and keeps no list. Text in any other language gets no
/// vector, so it is still found by words. Models load on first use, not at launch.
public final class AppleSentenceEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public static let identifier = "apple.nl.sentence"
    /// The English model's size. `embed` is English only, so this is the default space.
    public static let vectorSize = 512
    static let defaultTag = NLLanguage.english.rawValue

    /// Above this, the recognizer's top language is believed.
    static let confidentLanguage = 0.7
    /// Cosines from these models run low: for English, right answers have a median near 0.29 and
    /// wrong ones near 0.11 (docs/spikes/embedding-model.md).
    static let defaultFloor: Float = 0.15

    public let id = AppleSentenceEmbeddingProvider.identifier
    public let dimension = AppleSentenceEmbeddingProvider.vectorSize
    public let runsOnDevice = true
    public let similarityFloor: Float = AppleSentenceEmbeddingProvider.defaultFloor

    private let lock = NSLock()
    private var loaded = false
    private var models: [String: NLEmbedding] = [:]

    public init() {}

    public var isAvailable: Bool {
        !spaces.isEmpty
    }

    public var spaces: [EmbeddingSpace] {
        lock.withLock {
            load()
            return models.map { EmbeddingSpace(tag: $0.key, dimension: $0.value.dimension) }
                .sorted { $0.tag < $1.tag }
        }
    }

    public func similarityFloor(inSpace space: String) -> Float {
        Self.floors[space] ?? Self.defaultFloor
    }

    /// The English vector. Callers that compare vectors of different texts, such as the type
    /// classifier, use this so every vector is in one space.
    public func embed(_ text: String) async throws -> [Float] {
        try lock.withLock {
            load()
            guard let model = models[Self.defaultTag], Self.looksEnglish(text) else {
                throw EmbeddingTextError.unsupportedLanguage
            }
            return try Self.vector(model, text)
        }
    }

    public func embedTagged(_ text: String) async throws -> TaggedVector {
        try lock.withLock {
            load()
            guard let tag = Self.language(of: text, supported: Set(models.keys)), let model = models[tag] else {
                throw EmbeddingTextError.unsupportedLanguage
            }
            return try TaggedVector(space: tag, vector: Self.vector(model, text))
        }
    }

    // MARK: - Private

    private static func vector(_ model: NLEmbedding, _ text: String) throws -> [Float] {
        guard let vector = model.vector(for: text), vector.count == model.dimension else {
            throw EmbeddingTextError.noVector
        }
        return vector.map { Float($0) }
    }

    /// Asks the OS which languages have a sentence model. The revision check is cheap and weeds out
    /// codes with no model. Call with `lock` held.
    private func load() {
        guard !loaded else { return }
        loaded = true
        for code in Locale.LanguageCode.isoLanguageCodes {
            let language = NLLanguage(code.identifier)
            guard NLEmbedding.currentSentenceEmbeddingRevision(for: language) != 0,
                  let model = NLEmbedding.sentenceEmbedding(for: language) else { continue }
            models[language.rawValue] = model
        }
    }

    /// The language of `text`, if the OS has a model for it. Nothing when the text is clearly in
    /// another language. A short or mixed text that the recognizer can't place goes to the most
    /// likely language that has a model, or to English.
    static func language(of text: String, supported: Set<String>) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
        return pick(recognizer.languageHypotheses(withMaximum: 5), supported: supported)
    }

    static func pick(_ hypotheses: [NLLanguage: Double], supported: Set<String>) -> String? {
        let ranked = hypotheses.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
        if let top = ranked.first, top.value >= confidentLanguage {
            return supported.contains(top.key.rawValue) ? top.key.rawValue : nil
        }
        if let guess = ranked.first(where: { supported.contains($0.key.rawValue) }) {
            return guess.key.rawValue
        }
        return supported.contains(defaultTag) ? defaultTag : nil
    }

    private static func looksEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first else { return true }
        return top.key.rawValue == defaultTag || top.value < confidentLanguage
    }

    /// Per language, from the sweeps in docs/spikes/embedding-model.md. Spanish, French, Italian and
    /// Portuguese cosines run high (right and wrong answers both sit above 0.45), so a floor there
    /// only trims the bottom. German runs low and loses answers above 0.1. A language not listed
    /// uses `defaultFloor`.
    static let floors: [String: Float] = ["es": 0.3, "fr": 0.3, "it": 0.3, "pt": 0.3, "de": 0.05]
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
