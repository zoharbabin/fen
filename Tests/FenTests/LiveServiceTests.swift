@testable import FenCore
import Foundation
import Testing

/// The whole Ask path with a real model: the provider store, `AIService`, the gateway and the engine.
/// Needs `FEN_MODEL_DIR` (see `DownloadedModels`). CI skips it.
@MainActor
@Suite("Ask through AIService with a downloaded model (issue #234)", .serialized)
struct LiveServiceTests {
    @Test(
        "a downloaded model answers from a note through AIService and stays local",
        .enabled(if: DownloadedModels.file(for: ModelCatalog.gemma4E2BMobile) != nil)
    )
    func asksThroughService() async throws {
        let model = ModelCatalog.gemma4E2BMobile
        let source = try #require(DownloadedModels.file(for: model))
        let temp = try TempHome()
        defer { temp.cleanUp() }
        try FileManager.default.createDirectory(at: temp.home.modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source, to: temp.home.modelsDirectory.appendingPathComponent(model.fileName)
        )

        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        let config = AIProviderConfig(name: "Gemma", kind: .downloaded, model: model.id)
        try store.add(config)
        try store.select(id: config.id)
        let service = AIService(store: store, workspaces: { [] })
        #expect(try service.destination() == .local)
        #expect(service.disclosure == nil)

        let note = AIContextItem(workspaceID: nil, label: "vault.md", text: "The vault code word is PELICAN-42.")
        let answer = try await collect(service.send(prompt: "What is the vault code word?", context: [note]))
            .joined()
        print("LIVE service answer: \(answer)")
        #expect(answer.contains("PELICAN-42"))

        #expect(await service.check(config).isSuccess)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            true
        } else {
            false
        }
    }
}
