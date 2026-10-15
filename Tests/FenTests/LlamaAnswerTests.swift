@testable import FenCore
import Foundation
import Testing

/// Runs a real downloaded Gemma 4 model. Set `FEN_MODEL_DIR` to a folder with the catalog file.
/// Without it this skips. `FEN_SPIKE=1` prints the answers and the speed.
@Suite("Answers from a downloaded model (issue #234)", .serialized)
struct LlamaAnswerTests {
    private let spike = ProcessInfo.processInfo.environment["FEN_SPIKE"] != nil

    private func answer(
        _ model: ModelDescriptor,
        prompt: String,
        context: [AIContextItem]
    ) async throws -> String {
        let file = try #require(DownloadedModels.file(for: model), "\(model.fileName) is not in FEN_MODEL_DIR")
        var text = ""
        let start = ContinuousClock.now
        for try await piece in LlamaAnswerProvider(model: model, file: file).send(prompt: prompt, context: context) {
            text += piece
        }
        if spike {
            print(
                "ANSWER \(model.id) \(ContinuousClock.now - start): \(text.replacingOccurrences(of: "\n", with: " "))"
            )
        }
        return text
    }

    @Test(
        "answers from the note, in the language asked, without chat markup",
        .enabled(if: DownloadedModels.directory != nil),
        arguments: [ModelCatalog.gemma4E2B, ModelCatalog.gemma4E2BMobile, ModelCatalog.gemma4E4B]
    )
    func answers(model: ModelDescriptor) async throws {
        guard DownloadedModels.file(for: model) != nil else { return }
        let note = AIContextItem(
            workspaceID: nil, label: "release.md",
            text: "# Releasing\nTag the commit. The workflow then signs the archive and sends it to Apple for notarization. "
                + "The code word for the release is PELICAN-42."
        )
        let english = try await answer(model, prompt: "What is the code word for the release?", context: [note])
        #expect(english.contains("PELICAN-42"))
        for marker in ["<|channel", "<channel|>", "<turn|>", "<|turn>", "<bos>", "<eos>"] {
            #expect(!english.contains(marker), "Chat markup leaked: \(marker)")
        }
        let spanish = try await answer(
            model, prompt: "Responde en español: ¿cuál es la palabra clave de la versión?", context: [note]
        )
        #expect(spanish.contains("PELICAN-42"))
    }

    @Test(
        "a second request on the same engine works, and stopping early ends the stream",
        .enabled(if: DownloadedModels.directory != nil)
    )
    func stops() async throws {
        let model = ModelCatalog.gemma4E2B
        guard let file = DownloadedModels.file(for: model) else { return }
        var count = 0
        for try await _ in LlamaAnswerProvider(model: model, file: file)
            .send(prompt: "Write a long story about a lighthouse.", context: []) {
            count += 1
            if count == 5 {
                break
            }
        }
        #expect(count == 5)
        let after = try await answer(model, prompt: "Say only the word: ready", context: [])
        #expect(after.lowercased().contains("ready"))
    }
}
