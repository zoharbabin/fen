@testable import FenCore
import Foundation
import Testing

private func sse(_ events: [String]) -> [Data] {
    events.map { Data("data: \($0)\n\n".utf8) }
}

private func delta(_ text: String) -> String {
    #"{"choices":[{"delta":{"content":"\#(text)"}}]}"#
}

@Suite("OpenAI-compatible provider", .serialized)
struct OpenAICompatibleProviderTests {
    private func provider(_ server: LoopbackServer, apiKey: String? = nil) throws -> OpenAICompatibleProvider {
        try OpenAICompatibleProvider(
            endpoint: AIEndpoint("\(server.baseURL)/v1"),
            model: "test-model",
            apiKey: apiKey,
            session: AIHTTP.makeSession()
        )
    }

    @Test("streams the pieces in order and stops at [DONE]")
    func streams() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(chunks: sse([
                #"{"choices":[{"delta":{"role":"assistant"}}]}"#, delta("Hel"), delta("lo"), "[DONE]", delta("ignored"),
            ]))
        }
        defer { server.stop() }
        let pieces = try await collect(provider(server).send(prompt: "Hi", context: []))
        #expect(pieces == ["Hel", "lo"])
    }

    @Test("sends the model, stream flag, document context, and the key")
    func requestShape() async throws {
        let server = try await LoopbackServer
            .start { _ in LoopbackServer.Response(chunks: sse([delta("ok"), "[DONE]"])) }
        defer { server.stop() }
        let context = [AIContextItem(workspaceID: nil, label: "notes/a.md", text: "Body text")]
        _ = try await collect(provider(server, apiKey: "sk-test-123").send(prompt: "Summarize", context: context))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        #expect(request.headers["authorization"] == "Bearer sk-test-123")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "test-model")
        #expect(body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.first?["role"] == "system")
        let user = try #require(messages.last?["content"])
        #expect(user.contains(#"<document path="notes/a.md">"#) && user.contains("Body text"))
        #expect(user.hasSuffix("Summarize"))
    }

    @Test("sends no Authorization header without a key")
    func noKeyNoHeader() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response(chunks: sse(["[DONE]"])) }
        defer { server.stop() }
        _ = try await collect(provider(server).send(prompt: "Hi", context: []))
        #expect(server.requests.first?.headers["authorization"] == nil)
    }

    @Test("maps an error status to the provider's message")
    func errorStatus() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(status: 401, chunks: [Data(#"{"error":{"message":"Bad key"}}"#.utf8)])
        }
        defer { server.stop() }
        await #expect(throws: AIError.http(status: 401, message: "Bad key")) {
            try await collect(provider(server).send(prompt: "Hi", context: []))
        }
    }

    @Test("an error inside the stream is raised")
    func midStreamError() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(chunks: sse([delta("a"), #"{"error":{"message":"overloaded"}}"#]))
        }
        defer { server.stop() }
        await #expect(throws: AIError.http(status: 200, message: "overloaded")) {
            try await collect(provider(server).send(prompt: "Hi", context: []))
        }
    }

    @Test("a redirect is refused and never followed")
    func redirectRefused() async throws {
        let other = try await LoopbackServer.start { _ in LoopbackServer.Response(chunks: sse(["[DONE]"])) }
        defer { other.stop() }
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(status: 302, headers: ["Location": "\(other.baseURL)/steal"])
        }
        defer { server.stop() }
        await #expect(throws: AIError.redirectRefused) {
            try await collect(provider(server, apiKey: "sk-secret").send(prompt: "Hi", context: []))
        }
        #expect(other.connections == 0)
    }

    @Test("an unreachable server fails instead of hanging")
    func unreachable() async throws {
        let server = try await LoopbackServer.start { _ in LoopbackServer.Response() }
        let closed = try provider(server)
        server.stop()
        await #expect(throws: (any Error).self) {
            try await collect(closed.send(prompt: "Hi", context: []))
        }
    }

    @Test("cancelling the consumer closes the connection")
    func cancellation() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(chunks: sse([delta("first")]), holdOpen: true)
        }
        defer { server.stop() }
        let stream = try provider(server).send(prompt: "Hi", context: [])
        let task = Task { try await collect(stream) }
        #expect(try await pollUntilTrue { server.requests.count == 1 })
        task.cancel()
        #expect(try await pollUntilTrue { server.clientClosed == 1 })
    }
}

@Suite("Ollama provider", .serialized)
struct OllamaProviderTests {
    private func provider(_ server: LoopbackServer) throws -> OllamaProvider {
        try OllamaProvider(endpoint: AIEndpoint(server.baseURL), model: "llama3", session: AIHTTP.makeSession())
    }

    private func lines(_ objects: [String]) -> [Data] {
        objects.map { Data(($0 + "\n").utf8) }
    }

    @Test("streams newline-delimited JSON until done")
    func streams() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(chunks: lines([
                #"{"message":{"role":"assistant","content":"Hel"},"done":false}"#,
                #"{"message":{"role":"assistant","content":"lo"},"done":false}"#,
                #"{"message":{"role":"assistant","content":""},"done":true}"#,
            ]))
        }
        defer { server.stop() }
        let pieces = try await collect(provider(server).send(prompt: "Hi", context: []))
        #expect(pieces == ["Hel", "lo"])
        let request = try #require(server.requests.first)
        #expect(request.path == "/api/chat")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "llama3")
        #expect(body["stream"] as? Bool == true)
        // Thinking models stall for seconds on a short edit unless thinking is off.
        #expect(body["think"] as? Bool == false)
    }

    @Test("a missing model comes back as a readable error")
    func missingModel() async throws {
        let server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(status: 404, chunks: [Data(#"{"error":"model 'llama3' not found"}"#.utf8)])
        }
        defer { server.stop() }
        await #expect(throws: AIError.http(status: 404, message: "model 'llama3' not found")) {
            try await collect(provider(server).send(prompt: "Hi", context: []))
        }
    }

    @Test("an address that is not on this Mac is refused")
    func notLoopback() throws {
        #expect(throws: AIError.notLoopback(host: "api.example.com")) {
            try OllamaProvider(
                endpoint: AIEndpoint("https://api.example.com"), model: "m", session: AIHTTP.makeSession()
            )
        }
    }
}

@Suite("On-device provider")
struct OnDeviceProviderTests {
    @Test("is local, so only local-or-wider workspaces may use it")
    func isLocal() {
        #expect(OnDeviceProvider().destination == .local)
    }

    @Test(
        "answers a short prompt when the OS model is available",
        .enabled(if: OnDeviceModelAvailability.current == .available)
    )
    func answers() async throws {
        let pieces = try await collect(OnDeviceProvider().send(prompt: "Reply with the single word OK.", context: []))
        #expect(!pieces.joined().isEmpty)
    }

    @Test("says why it can't run when the OS model is unavailable")
    func unavailableMessage() {
        if case let .unavailable(reason) = OnDeviceModelAvailability.current {
            #expect(!reason.isEmpty)
        }
    }
}
