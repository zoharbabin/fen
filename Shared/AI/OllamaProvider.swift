import Foundation

/// Talks to Ollama's `/api/chat` (issue #4). Loopback only: the address must be on this Mac.
struct OllamaProvider: AIProvider {
    static let defaultAddress = "http://localhost:11434"

    let endpoint: AIEndpoint
    let model: String
    let session: URLSession

    init(endpoint: AIEndpoint, model: String, session: URLSession) throws {
        guard endpoint.isLoopback else { throw AIError.notLoopback(host: endpoint.host) }
        self.endpoint = endpoint
        self.model = model
        self.session = session
    }

    var destination: ModelDestination {
        .local
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Body: Encodable {
        let model: String
        let stream = true
        let messages: [Message]
    }

    private struct Reply: Decodable {
        let content: String?
    }

    private struct Chunk: Decodable {
        let message: Reply?
        let error: String?
        let done: Bool?
    }

    func send(prompt: String, context: [AIContextItem]) -> AsyncThrowingStream<String, Error> {
        let body = Body(model: model, messages: [
            Message(role: "system", content: AIPromptBuilder.instructions),
            Message(role: "user", content: AIPromptBuilder.userMessage(prompt: prompt, context: context)),
        ])
        let request: URLRequest
        do {
            request = try AIHTTP.jsonRequest(url: endpoint.appending("api/chat"), body: body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AIHTTP.stream(session: session, request: request) { line in
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(line.utf8)) else { return .skip }
            if let message = chunk.error {
                throw AIError.http(status: 200, message: message)
            }
            if let text = chunk.message?.content, !text.isEmpty {
                return .text(text)
            }
            return chunk.done == true ? .done : .skip
        }
    }
}
