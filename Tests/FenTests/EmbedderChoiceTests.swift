@testable import FenCore
import Foundation
import Testing

@Suite("Embedder choice (issue #35)")
struct EmbedderChoiceTests {
    private func defaults(_ value: String?) -> UserDefaults {
        let suite = UserDefaults(suiteName: "fen-embedder-\(UUID().uuidString)")!
        if let value {
            suite.set(value, forKey: EmbedderChoice.defaultsKey)
        }
        return suite
    }

    @Test("unset or unknown values give the built-in model")
    func defaultsToApple() {
        #expect(EmbedderChoice.current(defaults(nil)) == .apple)
        #expect(EmbedderChoice.current(defaults("nonsense")) == .apple)
    }

    @Test("the saved choice maps to its provider, and both stay on this device")
    func providers() {
        #expect(EmbedderChoice.current(defaults("embeddingGemma")) == .embeddingGemma)
        #expect(EmbedderChoice.apple.makeProvider().id == AppleSentenceEmbeddingProvider.identifier)
        let gemma = EmbedderChoice.embeddingGemma.makeProvider()
        #expect(gemma.id == "ollama.embeddinggemma")
        #expect(gemma.dimension == 768)
        for choice in EmbedderChoice.allCases {
            #expect(choice.makeProvider().runsOnDevice)
        }
    }
}
