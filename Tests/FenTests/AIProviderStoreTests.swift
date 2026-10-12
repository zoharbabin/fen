@testable import FenCore
import Foundation
import Testing

@MainActor
@Suite("AIProviderStore and AIService", .serialized)
struct AIProviderStoreTests {
    private func openAI(_ server: LoopbackServer? = nil, name: String = "LM Studio") -> AIProviderConfig {
        AIProviderConfig(
            name: name, kind: .openAICompatible, baseURL: "\(server?.baseURL ?? "http://localhost:1")/v1", model: "m"
        )
    }

    @Test("nothing is written until you add a provider")
    func nothingWrittenEarly() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        try store.load()
        #expect(store.providers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temp.home.root.path))
    }

    @Test("providers and the selection survive a relaunch")
    func persists() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let secrets = MemorySecretStore()
        let store = AIProviderStore(home: temp.home, secrets: secrets)
        let first = openAI(name: "First")
        let second = AIProviderConfig(name: "Local", kind: .ollama, baseURL: "http://localhost:11434", model: "llama3")
        try store.add(first)
        try store.add(second)
        #expect(store.selectedID == first.id)
        try store.select(id: second.id)

        let reloaded = AIProviderStore(home: temp.home, secrets: secrets)
        try reloaded.load()
        #expect(reloaded.providers == [first, second])
        #expect(reloaded.selectedID == second.id)
    }

    @Test("the key goes to the secret store, never into the file")
    func keyStaysOutOfTheFile() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let secrets = MemorySecretStore()
        let store = AIProviderStore(home: temp.home, secrets: secrets)
        let config = openAI()
        try store.add(config, apiKey: "sk-very-secret")
        let text = try String(contentsOf: temp.home.aiProvidersFile, encoding: .utf8)
        #expect(!text.contains("sk-very-secret"))
        #expect(secrets.allSecrets == ["sk-very-secret"])
        #expect(store.hasAPIKey(for: config.id))

        try store.update(config, apiKey: "")
        #expect(!store.hasAPIKey(for: config.id))
    }

    @Test("removing a provider deletes its key and moves the selection on")
    func removeDeletesKey() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let secrets = MemorySecretStore()
        let store = AIProviderStore(home: temp.home, secrets: secrets)
        let first = openAI(name: "First")
        let second = openAI(name: "Second")
        try store.add(first, apiKey: "k1")
        try store.add(second)
        try store.remove(id: first.id)
        #expect(secrets.allSecrets.isEmpty)
        #expect(store.selectedID == second.id)
    }

    @Test("a bad provider is refused and not saved", arguments: [
        AIProviderConfig(name: "x", kind: .ollama, baseURL: "https://api.example.com", model: "m"),
        AIProviderConfig(name: "x", kind: .ollama, baseURL: "http://localhost:11434", model: " "),
        AIProviderConfig(name: "x", kind: .openAICompatible, baseURL: "http://api.example.com", model: "m"),
        AIProviderConfig(name: "x", kind: .openAICompatible, baseURL: "nonsense", model: "m"),
    ])
    func refusesBadConfig(config: AIProviderConfig) throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let secrets = MemorySecretStore()
        let store = AIProviderStore(home: temp.home, secrets: secrets)
        #expect(throws: AIError.self) { try store.add(config, apiKey: "k") }
        #expect(store.providers.isEmpty)
        #expect(secrets.allSecrets.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temp.home.aiProvidersFile.path))
    }

    @Test("a corrupt file throws and is left in place")
    func corruptFile() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        try temp.home.ensureExists()
        try Data("{nope".utf8).write(to: temp.home.aiProvidersFile)
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try String(contentsOf: temp.home.aiProvidersFile, encoding: .utf8) == "{nope")
    }

    @Test("the notice names the host only when content leaves this device")
    func disclosure() {
        let remote = AIProviderConfig(
            name: "x",
            kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            model: "m"
        )
        let loopback = AIProviderConfig(
            name: "x",
            kind: .openAICompatible,
            baseURL: "http://localhost:1234/v1",
            model: "m"
        )
        let lan = AIProviderConfig(
            name: "x",
            kind: .openAICompatible,
            baseURL: "http://192.168.1.9:1234/v1",
            model: "m"
        )
        #expect(remote.disclosure == "This sends content to api.openai.com.")
        #expect(lan.disclosure == "This sends content to 192.168.1.9.")
        #expect(loopback.disclosure == nil)
        #expect(AIProviderConfig(name: "x", kind: .onDevice).disclosure == nil)
    }

    // MARK: - AIService

    @Test("with no provider set up, nothing is sent and nothing connects")
    func notConfigured() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response() }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let service = AIService(
            store: AIProviderStore(home: temp.home, secrets: MemorySecretStore()),
            workspaces: { [] }
        )
        #expect(!service.isConfigured)
        #expect(throws: AIError.notConfigured) { try service.send(prompt: "Hi") }
        #expect(server.connections == 0)
    }

    @Test("sends through the selected provider")
    func sendsThroughSelected() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response(chunks: sseEvents(["Hi", "!"])) }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        try store.add(openAI(server), apiKey: "k")
        let service = AIService(store: store, workspaces: { [] })
        let pieces = try await collect(service.send(prompt: "Hello"))
        #expect(pieces == ["Hi", "!"])
        #expect(server.requests.first?.headers["authorization"] == "Bearer k")
    }

    @Test("a workspace set to None is refused before any connection", arguments: AIDataAccess.allCases)
    func workspaceGate(access: AIDataAccess) async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response(chunks: sseEvents(["ok"])) }
        defer { server.stop() }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        try store.add(openAI(server))
        let space = Workspace(name: "Notes", path: "/tmp/n", settings: WorkspaceSettings(aiDataAccess: access))
        let service = AIService(store: store, workspaces: { [space] })
        let context = [AIContextItem(workspaceID: space.id, label: "a.md", text: "private")]
        if access == .none {
            #expect(throws: AIError.self) { try service.send(prompt: "Hi", context: context) }
            #expect(server.connections == 0)
        } else {
            // The test server is on loopback, so both other settings allow it.
            #expect(try await collect(service.send(prompt: "Hi", context: context)) == ["ok"])
        }
    }

    @Test("a remote provider is refused for a local-only workspace without any request")
    func remoteRefusedForLocalOnly() throws {
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        try store.add(AIProviderConfig(
            name: "Cloud",
            kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            model: "m"
        ))
        let space = Workspace(name: "Notes", path: "/tmp/n")
        #expect(space.settings.aiDataAccess == .localProvidersOnly)
        let service = AIService(store: store, workspaces: { [space] })
        let context = [AIContextItem(workspaceID: space.id, label: "a.md", text: "private")]
        #expect(throws: AIError.workspaceDisallows(
            workspace: "Notes",
            access: .localProvidersOnly,
            destination: .remote
        )) {
            try service.send(prompt: "Hi", context: context)
        }
    }

    @Test("check reports success and failure")
    func check() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response(chunks: sseEvents(["OK"])) }
        let temp = try TempHome()
        defer { temp.cleanUp() }
        let store = AIProviderStore(home: temp.home, secrets: MemorySecretStore())
        let service = AIService(store: store, workspaces: { [] })
        let config = openAI(server)
        if case let .failure(error) = await service.check(config) {
            Issue.record("expected success, got \(error)")
        }
        server.stop()
        if case .success = await service.check(config) {
            Issue.record("expected a failure once the server is gone")
        }
    }
}

private func sseEvents(_ pieces: [String]) -> [Data] {
    pieces.map { Data(#"data: {"choices":[{"delta":{"content":"\#($0)"}}]}"#.utf8 + Data("\n\n".utf8)) }
        + [Data("data: [DONE]\n\n".utf8)]
}

@MainActor
@Suite("EmbeddingProviderRegistry")
struct EmbeddingProviderRegistryTests {
    private struct Fake: EmbeddingProvider {
        let id: String
        let runsOnDevice: Bool
        let dimension = 3
        func embed(_: String) async throws -> [Float] {
            [0, 0, 0]
        }
    }

    @Test("an off-device provider can't be registered")
    func refusesRemote() {
        let registry = EmbeddingProviderRegistry()
        #expect(throws: EmbeddingProviderError(providerID: "cloud")) {
            try registry.register(Fake(id: "cloud", runsOnDevice: false))
        }
        #expect(registry.providers.isEmpty)
    }

    @Test("a local provider registers, and registering again replaces it")
    func acceptsLocal() throws {
        let registry = EmbeddingProviderRegistry()
        try registry.register(Fake(id: "local", runsOnDevice: true))
        try registry.register(Fake(id: "local", runsOnDevice: true))
        #expect(registry.providers.count == 1)
    }
}

@Suite("KeychainSecretStore")
struct KeychainSecretStoreTests {
    @Test("writes, reads, replaces, and deletes a secret")
    func roundTrip() throws {
        let store = KeychainSecretStore(service: "app.fen.tests.\(UUID().uuidString)")
        let account = UUID().uuidString
        defer { try? store.delete(account: account) }
        #expect(try store.read(account: account) == nil)
        try store.write("one", account: account)
        #expect(try store.read(account: account) == "one")
        try store.write("two", account: account)
        #expect(try store.read(account: account) == "two")
        try store.delete(account: account)
        #expect(try store.read(account: account) == nil)
        try store.delete(account: account)
    }
}
