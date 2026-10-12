@testable import FenCore
import Foundation
import Testing

private func askSSE(_ pieces: [String]) -> [Data] {
    pieces.map { Data(#"data: {"choices":[{"delta":{"content":"\#($0)"}}]}"#.utf8 + Data("\n\n".utf8)) }
        + [Data("data: [DONE]\n\n".utf8)]
}

@Suite("Ask your workspaces (issue #141)", .serialized)
@MainActor
struct AskControllerTests {
    @MainActor
    private struct Fixture {
        let home: TempHome
        let notes: TempFolder
        let otherFolder: TempFolder
        let library: WorkspaceLibrary
        let server: LoopbackServer
        let service: AIService
        let controller: AskController
        let notesID: UUID
        let privateID: UUID

        init(reply: [String] = ["We charge per seat [1]."], configured: Bool = true) async throws {
            home = try TempHome()
            notes = try TempFolder("ask-notes")
            otherFolder = try TempFolder("ask-private")
            try notes.write(
                "pricing.md",
                "# Pricing\n\nIntro line.\n\n## Decision\n\n"
                    + "We decided to charge per seat, not per usage. The price is twelve dollars per seat each month.\n"
            )
            try notes.write("cooking.md", "# Cooking\nBake bread for dinner tonight with flour and yeast.\n")
            try otherFolder.write(
                "salary.md",
                "# Salary plan\nThe secret salary plan pays ninety thousand dollars per seat of staff.\n"
            )
            let library = WorkspaceLibrary(home: home.home, watching: false, embedder: FakeEmbedder())
            let first = try library.add(folder: notes.root, name: "Notes")
            let second = try library.add(folder: otherFolder.root, name: "Private")
            try library.updateSettings(id: second.id) { $0.aiDataAccess = AIDataAccess.none }
            let ready = try await pollUntilTrue(timeout: .seconds(30)) {
                let notesStatus = library.indexStatus(for: first.id)
                let otherStatus = library.indexStatus(for: second.id)
                return notesStatus.phase == .idle && notesStatus.documents == 2
                    && otherStatus.phase == .idle && otherStatus.documents == 1
            }
            try #require(ready)
            let reply = reply
            server = try await LoopbackServer.start { _ in LoopbackServer.Response(chunks: askSSE(reply)) }
            let store = AIProviderStore(home: home.home, secrets: MemorySecretStore())
            if configured {
                try store.add(AIProviderConfig(
                    name: "Local", kind: .openAICompatible, baseURL: "\(server.baseURL)/v1", model: "m"
                ))
            }
            service = AIService(store: store, workspaces: { library.registry.workspaces })
            self.library = library
            controller = AskController(library: library, service: service)
            notesID = first.id
            privateID = second.id
        }

        func cleanUp() {
            server.stop()
            home.cleanUp()
            notes.cleanUp()
            otherFolder.cleanUp()
        }

        func finish() async throws {
            let done = try await pollUntilTrue(timeout: .seconds(30)) {
                !controller.isWorking && controller.phase != .idle
            }
            try #require(done)
        }

        /// The message texts the model received, with JSON escapes decoded.
        var sentText: String {
            var texts: [String] = []
            for request in server.requests {
                let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
                for message in (body?["messages"] as? [[String: String]]) ?? [] {
                    texts.append(message["content"] ?? "")
                }
            }
            return texts.joined(separator: "\n")
        }
    }

    @Test("a question gets a streamed answer over the chosen workspace, with no file open")
    func answers() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.ask("What did we decide about pricing per seat?", scope: .workspace(fixture.notesID))
        try await fixture.finish()
        #expect(fixture.controller.phase == .done)
        #expect(fixture.controller.answer == "We charge per seat [1].")
        #expect(fixture.controller.citedPassages.map(\.relativePath) == ["pricing.md"])
        #expect(!fixture.controller.hasUnsupportedStatements)
        #expect(fixture.sentText.contains("twelve dollars per seat"))
        #expect(fixture.sentText.contains("[1] Notes/pricing.md"))
    }

    @Test("a cited passage is found at the cited lines of the real file")
    func citationMatchesTheFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.ask("What did we decide about pricing per seat?", scope: .workspace(fixture.notesID))
        try await fixture.finish()
        let cited = try #require(fixture.controller.citedPassages.first)
        let file = try String(
            contentsOf: fixture.notes.root.appendingPathComponent(cited.relativePath),
            encoding: .utf8
        )
        let lines = file.components(separatedBy: "\n")
        #expect(cited.startLine >= 1)
        #expect(cited.endLine <= lines.count)
        let covered = lines[(cited.startLine - 1) ..< cited.endLine].joined(separator: "\n")
        #expect(covered.contains("We decided to charge per seat"))
        #expect(cited.text.contains("twelve dollars"))
        for line in cited.text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            #expect(covered.contains(line), "line not found at the cited place: \(line)")
        }
    }

    @Test("a citation link in the answer points to its passage")
    func linkTarget() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.ask("What did we decide about pricing per seat?", scope: .workspace(fixture.notesID))
        try await fixture.finish()
        let link = try #require(fixture.controller.linkedAnswer.runs.compactMap(\.link).first)
        #expect(fixture.controller.passage(for: link)?.relativePath == "pricing.md")
        #expect(try fixture.controller.passage(for: #require(URL(string: "fen-passage://9"))) == nil)
        #expect(try fixture.controller.passage(for: #require(URL(string: "https://example.com"))) == nil)
    }

    @Test("a question nothing matches says so and never calls the model")
    func nothingFound() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.ask("Zebra quantum xylophone", scope: .workspace(fixture.notesID))
        try await fixture.finish()
        #expect(fixture.controller.phase == .notFound)
        #expect(fixture.controller.answer == "Not found in the selected workspaces.")
        #expect(fixture.server.connections == 0)
    }

    @Test("when the model says the passages do not answer, the result is not found")
    func modelSaysNotFound() async throws {
        let fixture = try await Fixture(reply: ["Not found in the selected workspaces."])
        defer { fixture.cleanUp() }
        fixture.controller.ask("What did we decide about pricing per seat?", scope: .workspace(fixture.notesID))
        try await fixture.finish()
        #expect(fixture.controller.phase == .notFound)
        #expect(fixture.controller.citedPassages.isEmpty)
    }

    @Test("an answer with a made-up source number or an uncited claim is flagged")
    func flagsWeakAnswers() async throws {
        let fixture =
            try await Fixture(reply: ["Seats cost twelve dollars each month [5]. Teams may pay yearly instead."])
        defer { fixture.cleanUp() }
        fixture.controller.ask("What did we decide about pricing per seat?", scope: .workspace(fixture.notesID))
        try await fixture.finish()
        #expect(fixture.controller.phase == .done)
        #expect(fixture.controller.hasUnsupportedStatements)
        #expect(fixture.controller.citedPassages.isEmpty)
    }

    @Test("the question never writes a file, in the workspace or beside it")
    func readOnly() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let before = try snapshot(of: [fixture.notes.root, fixture.otherFolder.root])
        fixture.controller.ask("What did we decide about pricing per seat?", scope: .all)
        try await fixture.finish()
        #expect(try snapshot(of: [fixture.notes.root, fixture.otherFolder.root]) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.notes.root.appendingPathComponent(".fen").path))
    }

    private func snapshot(of roots: [URL]) throws -> [String: String] {
        var seen: [String: String] = [:]
        for root in roots {
            let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
            while let url = walker?.nextObject() as? URL {
                let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let body = (try? Data(contentsOf: url)).map { String($0.count) } ?? "dir"
                seen[url.path] = "\(body) \(date?.timeIntervalSince1970 ?? 0)"
            }
        }
        return seen
    }

    @Test("a workspace set to None is left out, named, and none of its text is sent")
    func dataAccessNone() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.ask("How much is the salary plan per seat?", scope: .all)
        try await fixture.finish()
        #expect(fixture.controller.skipped == ["Private"])
        #expect(fixture.controller.passages.allSatisfy { $0.workspaceID == fixture.notesID })
        #expect(!fixture.sentText.contains("secret salary"))
        #expect(!fixture.sentText.contains("Private"))
    }

    @Test("a local-only workspace is left out for a remote provider, and nothing is sent")
    func remoteProvider() async throws {
        let fixture = try await Fixture(configured: false)
        defer { fixture.cleanUp() }
        try fixture.library.updateSettings(id: fixture.notesID) { $0.aiDataAccess = .localProvidersOnly }
        let store = AIProviderStore(home: fixture.home.home, secrets: MemorySecretStore())
        try store.add(AIProviderConfig(
            name: "Cloud", kind: .openAICompatible, baseURL: "https://api.example.com/v1", model: "m"
        ), apiKey: "k")
        let library = fixture.library
        let service = AIService(store: store, workspaces: { library.registry.workspaces })
        let controller = AskController(library: library, service: service)
        controller.ask("What did we decide about pricing per seat?", scope: .all)
        let done = try await pollUntilTrue(timeout: .seconds(30)) { !controller.isWorking && controller.phase != .idle }
        try #require(done)
        #expect(controller.phase == .notFound)
        #expect(controller.passages.isEmpty)
        #expect(Set(controller.skipped) == ["Notes", "Private"])
        #expect(fixture.server.connections == 0)
    }

    @Test("with no provider set up, it says so and nothing connects")
    func notConfigured() async throws {
        let fixture = try await Fixture(configured: false)
        defer { fixture.cleanUp() }
        fixture.controller.ask("What did we decide about pricing per seat?", scope: .all)
        try await fixture.finish()
        #expect(fixture.controller.phase == .failed(AIError.notConfigured.localizedDescription))
        #expect(fixture.server.connections == 0)
    }

    @Test("a provider that fails shows its error and keeps the passages")
    func providerFailure() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.server.stop()
        fixture.controller.ask("What did we decide about pricing per seat?", scope: .workspace(fixture.notesID))
        try await fixture.finish()
        guard case .failed = fixture.controller.phase else {
            Issue.record("expected a failure, got \(fixture.controller.phase)")
            return
        }
    }
}

@Suite("Ask cancel (issue #141)", .serialized)
@MainActor
struct AskCancelTests {
    @Test("stopping an answer closes the request and keeps what arrived")
    func stopCloses() async throws {
        let home = try TempHome()
        let folder = try TempFolder("ask-cancel")
        defer { home.cleanUp()
            folder.cleanUp()
        }
        try folder.write("pricing.md", "# Pricing\nWe charge per seat each month.\n")
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: FakeEmbedder())
        let workspace = try library.add(folder: folder.root)
        let ready = try await pollUntilTrue(timeout: .seconds(30)) {
            let status = library.indexStatus(for: workspace.id)
            return status.phase == .idle && status.documents == 1
        }
        try #require(ready)
        let server = try await LoopbackServer.start { _ in
            var response = LoopbackServer.Response(chunks: askSSE(["We charge"]).dropLast().map(\.self))
            response.holdOpen = true
            // Without a content type, the system buffers a small body before it shows any of it.
            response.headers["Content-Type"] = "text/event-stream"
            return response
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
        let controller = AskController(library: library, service: service)
        controller.ask("How much do we charge per seat?", scope: .all)
        let got = try await pollUntilTrue { controller.answer == "We charge" }
        #expect(got)
        controller.cancel()
        #expect(controller.phase == .idle)
        #expect(try await pollUntilTrue { server.clientClosed == 1 })
        #expect(controller.answer == "We charge")
    }
}
