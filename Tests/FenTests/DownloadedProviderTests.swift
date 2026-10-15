@testable import FenCore
import Foundation
import Testing

@MainActor
@Suite("Downloaded models as providers and prompts (issue #234)")
struct DownloadedProviderTests {
    private func config(model: String) -> AIProviderConfig {
        AIProviderConfig(name: "Gemma", kind: .downloaded, model: model)
    }

    /// A file of the model's exact size that takes no disk space. The checksum is checked at install.
    private func installSparse(_ model: ModelDescriptor, in temp: TempHome) throws {
        try FileManager.default.createDirectory(at: temp.home.modelsDirectory, withIntermediateDirectories: true)
        let url = temp.home.modelsDirectory.appendingPathComponent(model.fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(model.byteCount))
    }

    @Test("only an answer model from the catalog is a valid downloaded provider")
    func validate() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        try store.validate(config(model: ModelCatalog.gemma4E2B.id))
        #expect(throws: AIError.missingModel) { try store.validate(config(model: "nope")) }
        #expect(throws: AIError.missingModel) { try store.validate(config(model: ModelCatalog.embeddingGemma2.id)) }
    }

    @Test("a model that is not installed is refused with its name")
    func notInstalled() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        let model = ModelCatalog.gemma4E2B
        #expect(throws: AIError.modelNotInstalled(model.displayName)) {
            _ = try store.makeProvider(for: config(model: model.id))
        }
    }

    @Test("an installed answer model gives a provider that stays on this device")
    func installed() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = ModelCatalog.gemma4E2B
        try installSparse(model, in: temp)
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        let provider = try store.makeProvider(for: config(model: model.id))
        #expect(provider.destination == .local)
    }

    @Test("a downloaded provider survives a relaunch and keeps no key")
    func persists() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let secrets = MemorySecretStore()
        let store = AIProviderStore(home: temp.home, secrets: secrets)
        let added = config(model: ModelCatalog.gemma4E2B.id)
        try store.add(added)
        let reloaded = AIProviderStore(home: temp.home, secrets: secrets)
        try reloaded.load()
        #expect(reloaded.providers == [added])
        #expect(secrets.allSecrets.isEmpty)
    }

    @Test("the search choice falls back to the built-in model when the file is gone")
    func embedderFallback() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        #expect(EmbedderChoice.offered(home: temp.home) == [.apple, .embeddingGemma])
        let provider = EmbedderChoice.downloadedQwen3.makeProvider(home: temp.home)
        #expect(provider.id == AppleSentenceEmbeddingProvider.identifier)
    }

    @Test("an installed embedding model is listed and gives its own provider")
    func embedderInstalled() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let model = ModelCatalog.qwen3Embedding
        // A file of the wrong size is not installed.
        try FileManager.default.createDirectory(at: temp.home.modelsDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: temp.home.modelsDirectory.appendingPathComponent(model.fileName))
        #expect(!EmbedderChoice.offered(home: temp.home).contains(.downloadedQwen3))
        try installSparse(model, in: temp)
        #expect(EmbedderChoice.offered(home: temp.home) == [.apple, .embeddingGemma, .downloadedQwen3])
        #expect(EmbedderChoice.downloadedQwen3.makeProvider(home: temp.home).id == "llama.\(model.id)")
    }

    @Test("each model family gets the prompt it was trained with")
    func prompts() {
        #expect(LlamaPrompts.document("body", title: "Note", kind: .embeddingGemma2) == "title: Note | text: body")
        #expect(LlamaPrompts.document("body", kind: .embeddingGemma2) == "title: none | text: body")
        #expect(LlamaPrompts.query("hello", kind: .embeddingGemma2) == "task: search result | query: hello")
        #expect(LlamaPrompts.document("body", title: "Note", kind: .qwen3Embedding) == "body")
        #expect(LlamaPrompts.query("hello", kind: .qwen3Embedding).hasSuffix("\nQuery:hello"))
        #expect(LlamaPrompts.query("hello", kind: .qwen3Embedding).hasPrefix("Instruct: "))
        #expect(
            LlamaPrompts.gemma4Chat(system: "S", user: "U")
                == "<bos><|turn>system\nS<turn|>\n<|turn>user\nU<turn|>\n<|turn>model\n"
        )
    }

    @Test("a hot device refuses to run a model: phones at serious, a Mac only at critical")
    func thermal() {
        for platform in [ModelPlatform.iPhone, .iPad] {
            #expect(LlamaAnswerProvider.refusesToRun(at: .serious, on: platform))
            #expect(!LlamaAnswerProvider.refusesToRun(at: .fair, on: platform))
        }
        #expect(!LlamaAnswerProvider.refusesToRun(at: .serious, on: .mac))
        for platform in [ModelPlatform.mac, .iPhone] {
            #expect(LlamaAnswerProvider.refusesToRun(at: .critical, on: platform))
            #expect(!LlamaAnswerProvider.refusesToRun(at: .nominal, on: platform))
        }
    }

    @Test("no model weights ship inside the app package")
    func noWeightsInPackage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == ".build" || name == ".git" || name == "node_modules" {
                enumerator.skipDescendants()
            }
            if ["gguf", "safetensors"].contains(url.pathExtension) {
                found.append(url.path)
            }
        }
        #expect(found.isEmpty, "Weights must be downloaded, never shipped: \(found)")
    }
}
