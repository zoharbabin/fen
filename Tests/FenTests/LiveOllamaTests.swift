@testable import FenCore
import Foundation
import Testing

/// The whole local stack on this Mac: EmbeddingGemma for search, Gemma 4 for answers. Needs Ollama
/// with `embeddinggemma` and `gemma4` pulled. Run: `FEN_LIVE_OLLAMA=1 swift test --no-parallel --filter LiveOllama`.
@Suite(
    "Live Ollama: Ask with citations (issues #141, #35, #4)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["FEN_LIVE_OLLAMA"] != nil)
)
@MainActor
struct LiveOllamaTests {
    private let questions: [(question: String, answer: String)] = [
        ("How do I get the app signed so people can open it?", "notarization.md"),
        ("When should I plant the tomatoes?", "tomatoes.md"),
        ("How much should I raise my weekly running distance?", "running-plan.md"),
    ]

    @Test("answers cite the file that holds the answer, and an unrelated question is not found")
    func askWithCitations() async throws {
        let embedder = try OllamaEmbeddingProvider()
        try #require(embedder.isAvailable, "Ollama isn't running or embeddinggemma isn't pulled.")
        let home = try TempHome()
        let folder = try TempFolder("live-ollama")
        defer { home.cleanUp()
            folder.cleanUp()
        }
        for (path, text) in RelatedCorpus.documents {
            try folder.write(path, text + "\n")
        }
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: embedder)
        let workspace = try library.add(folder: folder.root)
        let ready = try await pollUntilTrue(timeout: .seconds(120)) {
            let status = library.indexStatus(for: workspace.id)
            return status.phase == .idle && status.documents == RelatedCorpus.documents.count && status.isSemantic
        }
        try #require(ready)

        let store = AIProviderStore(home: home.home, secrets: MemorySecretStore())
        try store.add(AIProviderConfig(
            name: "Local Gemma",
            kind: .ollama,
            baseURL: OllamaEmbeddingProvider.defaultAddress,
            model: "gemma4:latest"
        ))
        let service = AIService(store: store, workspaces: { library.registry.workspaces })

        for item in questions {
            let controller = AskController(library: library, service: service)
            controller.ask(item.question, scope: .workspace(workspace.id))
            let done = try await pollUntilTrue(timeout: .seconds(240)) {
                !controller.isWorking && controller.phase != .idle
            }
            try #require(done)
            let cited = controller.citedPassages.map(\.relativePath)
            print("LIVE Q: \(item.question)\nLIVE A: \(controller.answer)\nLIVE cited: \(cited)")
            #expect(controller.phase == .done, "\(item.question): \(controller.phase)")
            #expect(controller.citedPassages.map(\.relativePath).contains(item.answer), "\(item.question)")
            #expect(controller.reading.invalid.isEmpty)
        }

        let controller = AskController(library: library, service: service)
        controller.ask("What is the capital of Australia?", scope: .workspace(workspace.id))
        let done = try await pollUntilTrue(timeout: .seconds(240)) { !controller.isWorking && controller.phase != .idle
        }
        try #require(done)
        print("LIVE unrelated: \(controller.phase) \(controller.answer)")
        #expect(controller.phase == .notFound || controller.reading.isNotFound)
    }

    private func makeStack(approval: ApprovalMode) async throws -> (InlineAIFixture, FileEnricher, WriteGate) {
        let fixture = try await InlineAIFixture(approval: approval)
        let store = AIProviderStore(home: fixture.home.home, secrets: MemorySecretStore())
        try store.add(AIProviderConfig(
            name: "Local Gemma",
            kind: .ollama,
            baseURL: OllamaEmbeddingProvider.defaultAddress,
            model: "gemma4:latest"
        ))
        let service = AIService(store: store, workspaces: { fixture.library.registry.workspaces })
        let gate = WriteGate(library: fixture.library)
        return (fixture, FileEnricher(library: fixture.library, service: service, gate: gate), gate)
    }

    @Test("Enrich adds a cited fact under the short bullet, keeps every line, logs it, and undo restores the file")
    func enrichWithAutoApprove() async throws {
        let (fixture, runner, gate) = try await makeStack(approval: .autoApprove)
        defer { fixture.cleanUp() }
        let result = try await runner.enrich(workspaceID: fixture.workspaceID, relativePath: "plan.md")
        let written = try String(contentsOf: fixture.planURL, encoding: .utf8)
        print("LIVE enrich result: \(result)\n\(written)")
        #expect(result == .applied)
        for line in inlineAIPlanText.components(separatedBy: "\n") where !line.isEmpty {
            #expect(written.contains(line))
        }
        #expect(written.contains("pricing.md"))
        let entry = try #require(gate.activity[fixture.workspaceID]?.first)
        #expect(entry.provenance.model == "gemma4:latest")
        try gate.undo(entry.id, workspaceID: fixture.workspaceID)
        #expect(try String(contentsOf: fixture.planURL, encoding: .utf8) == inlineAIPlanText)
    }

    @Test("Enrich in Ask mode queues a diff and leaves the file alone")
    func enrichInAskMode() async throws {
        let (fixture, runner, gate) = try await makeStack(approval: .ask)
        defer { fixture.cleanUp() }
        let result = try await runner.enrich(workspaceID: fixture.workspaceID, relativePath: "plan.md")
        #expect(result == .queued)
        #expect(try String(contentsOf: fixture.planURL, encoding: .utf8) == inlineAIPlanText)
        #expect(gate.pending(for: fixture.workspaceID).count == 1)
    }
}
