@testable import FenCore
import Foundation
import Testing

/// A hand-labeled spot-check of the passages "Ask your workspaces" (issue #141) hands to the model,
/// with the real on-device embedder. Each question has one file that holds the answer. Hit@3 asks
/// whether that file is among the first three passages. Set `FEN_SPIKE=1` to print the numbers.
private let questions: [(question: String, answer: String)] = [
    ("How do I get the app signed so people can open it?", "notarization.md"),
    ("Which release notes should I write after pushing the tag?", "release-notes.md"),
    ("What is the safest second step when logging in?", "two-factor.md"),
    ("How do I avoid fake emails that copy a real site?", "phishing.md"),
    ("When should I plant the tomatoes?", "tomatoes.md"),
    ("How often should the vegetable beds get water?", "watering.md"),
    ("How much should I raise my weekly running distance?", "running-plan.md"),
    ("Where do I put the version of the API?", "api-versioning.md"),
]

@Suite("Ask precision with the Apple embedder (issue #141)", .serialized)
@MainActor
struct AskPrecisionTests {
    private let provider = AppleSentenceEmbeddingProvider()

    @Test("the passage that answers a question is among the first three")
    func hitAtThree() async throws {
        try #require(provider.isAvailable, "The on-device sentence model isn't installed on this machine.")
        let home = try TempHome()
        let folder = try TempFolder("ask-precision")
        defer { home.cleanUp()
            folder.cleanUp()
        }
        for (path, text) in RelatedCorpus.documents {
            try folder.write(path, text + "\n")
        }
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: provider)
        let workspace = try library.add(folder: folder.root)
        let ready = try await pollUntilTrue(timeout: .seconds(120)) {
            let status = library.indexStatus(for: workspace.id)
            return status.phase == .idle && status.documents == RelatedCorpus.documents.count && status.isSemantic
        }
        try #require(ready)

        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(chunks: [Data("data: [DONE]\n\n".utf8)])
        }
        defer { server.stop() }
        let store = AIProviderStore(home: home.home, secrets: MemorySecretStore())
        try store.add(AIProviderConfig(
            name: "Local",
            kind: .openAICompatible,
            baseURL: "\(server.baseURL)/v1",
            model: "m"
        ))
        let service = AIService(store: store, workspaces: { library.registry.workspaces })

        var first = 0, topThree = 0
        for item in questions {
            let controller = AskController(library: library, service: service)
            controller.ask(item.question, scope: .workspace(workspace.id))
            let done = try await pollUntilTrue(timeout: .seconds(30)) {
                !controller.isWorking && controller.phase != .idle
            }
            try #require(done)
            let ranked = controller.passages.map(\.relativePath)
            first += ranked.first == item.answer ? 1 : 0
            topThree += ranked.prefix(3).contains(item.answer) ? 1 : 0
        }
        let count = Double(questions.count)
        if ProcessInfo.processInfo.environment["FEN_SPIKE"] != nil {
            print("ASK hit@1 \(Double(first) / count) hit@3 \(Double(topThree) / count)")
        }
        #expect(Double(topThree) / count >= 0.75)
    }
}
