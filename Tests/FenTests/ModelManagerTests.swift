import CryptoKit
@testable import FenCore
import Foundation
import Testing

private let managerPayload = Data("pretend these are model weights".utf8)

@MainActor
@Suite("ModelManager (issue #234)", .serialized)
struct ModelManagerTests {
    private static var digest: String {
        SHA256.hash(data: managerPayload).map { String(format: "%02x", $0) }.joined()
    }

    /// Same ids as the catalog entries, so the Search picker and answer provider find them.
    private func descriptor(
        id: String = "embeddinggemma-2-q8",
        kind: ModelKind = .embeddingGemma2,
        url: String = "https://models.example.com/m.gguf",
        sha256: String = ModelManagerTests.digest,
        fileName: String = "m.gguf"
    ) throws -> ModelDescriptor {
        try ModelDescriptor(
            id: id, displayName: "Test \(id)", url: #require(URL(string: url)), sha256: sha256,
            byteCount: Int64(managerPayload.count), fileName: fileName, licenseName: "Apache-2.0", kind: kind
        )
    }

    private func manager(_ temp: TempHome, _ models: [ModelDescriptor]) -> ModelManager {
        let store = ModelStore(home: temp.home, session: ModelStore.makeSession())
        return ModelManager(home: temp.home, store: store, catalog: models)
    }

    private func settled(_ manager: ModelManager, _ model: ModelDescriptor) async throws -> Bool {
        try await pollUntilTrue {
            if case .downloading = manager.state(for: model) {
                return false
            }
            return true
        }
    }

    @Test("a model that is not on disk is not installed, and a part on disk is reported")
    func initialStates() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor()
        #expect(manager(temp, [model]).state(for: model) == .notInstalled(partial: 0))
        try FileManager.default.createDirectory(at: temp.home.modelsDirectory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(to: temp.home.modelsDirectory.appendingPathComponent("m.gguf.part"))
        #expect(manager(temp, [model]).state(for: model) == .notInstalled(partial: 7))
    }

    @Test("a download installs the model, and delete removes it")
    func downloadAndDelete() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Length": "\(managerPayload.count)"], chunks: [managerPayload])
        }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "\(server.baseURL)/m.gguf")
        let manager = manager(temp, [model])
        manager.download(model)
        #expect(try await settled(manager, model))
        #expect(manager.state(for: model) == .installed)
        #expect(manager.isInstalled(model))
        #expect(ModelStore(home: temp.home).isInstalled(model))

        try manager.delete(model)
        #expect(manager.state(for: model) == .notInstalled(partial: 0))
        #expect(!ModelStore(home: temp.home).isInstalled(model))
    }

    @Test("a wrong checksum ends as a failure and installs nothing")
    func checksumFailure() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Length": "\(managerPayload.count)"], chunks: [managerPayload])
        }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "\(server.baseURL)/m.gguf", sha256: String(repeating: "0", count: 64))
        let manager = manager(temp, [model])
        manager.download(model)
        #expect(try await settled(manager, model))
        guard case .failed = manager.state(for: model) else {
            Issue.record("Expected a failure, got \(manager.state(for: model))")
            return
        }
        #expect(!ModelStore(home: temp.home).isInstalled(model))
    }

    @Test("cancel stops a download and leaves the model not installed")
    func cancel() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(
                headers: ["Content-Length": "\(managerPayload.count + 1000)"], chunks: [managerPayload], holdOpen: true
            )
        }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "\(server.baseURL)/m.gguf")
        let manager = manager(temp, [model])
        manager.download(model)
        #expect(try await pollUntilTrue { server.requests.count == 1 })
        manager.cancel(model)
        #expect(try await settled(manager, model))
        guard case .notInstalled = manager.state(for: model) else {
            Issue.record("Expected not installed, got \(manager.state(for: model))")
            return
        }
        #expect(!ModelStore(home: temp.home).isInstalled(model))
    }

    @Test("the Search picker lists a downloaded model only once it is installed")
    func offeredEmbedders() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Length": "\(managerPayload.count)"], chunks: [managerPayload])
        }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = try descriptor(url: "\(server.baseURL)/m.gguf")
        let manager = manager(temp, [model])
        #expect(manager.offeredEmbedders() == [.apple, .embeddingGemma])
        manager.download(model)
        #expect(try await settled(manager, model))
        #expect(manager.offeredEmbedders() == [.apple, .embeddingGemma, .downloadedEmbeddingGemma])
    }

    @Test("using a model for answers adds one provider and selects it, however often you ask")
    func useForAnswers() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let manager = manager(temp, [])
        let providers = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        let model = ModelCatalog.gemma4E2B
        #expect(!manager.isUsedForAnswers(model, in: providers))
        try manager.useForAnswers(model, in: providers)
        try manager.useForAnswers(model, in: providers)
        #expect(providers.providers.count == 1)
        #expect(providers.providers.first?.kind == .downloaded)
        #expect(manager.isUsedForAnswers(model, in: providers))

        let other = AIProviderConfig(name: "Local", kind: .ollama, baseURL: "http://localhost:11434", model: "llama3")
        try providers.add(other)
        try providers.select(id: other.id)
        #expect(!manager.isUsedForAnswers(model, in: providers))
        try manager.useForAnswers(model, in: providers)
        #expect(providers.providers.count == 2)
        #expect(manager.isUsedForAnswers(model, in: providers))
    }
}
