import Foundation

/// Talks to any server that speaks OpenAI's `/chat/completions` with streaming (issue #4). That
/// covers LM Studio, OpenRouter, OpenAI, and Ollama's compatible mode.
struct OpenAICompatibleProvider: AIProvider {
    let endpoint: AIEndpoint
    let model: String
    let apiKey: String?
    let session: URLSession

    var destination: ModelDestination {
        endpoint.destination
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

    private struct Delta: Decodable {
        let content: String?
    }

    private struct Choice: Decodable {
        let delta: Delta?
    }

    private struct Failure: Decodable {
        let message: String?
    }

    private struct Chunk: Decodable {
        let choices: [Choice]?
        let error: Failure?
    }

    func send(prompt: String, context: [AIContextItem]) -> AsyncThrowingStream<String, Error> {
        let body = Body(model: model, messages: [
            Message(role: "system", content: AIPromptBuilder.instructions),
            Message(role: "user", content: AIPromptBuilder.userMessage(prompt: prompt, context: context)),
        ])
        let request: URLRequest
        do {
            request = try AIHTTP.jsonRequest(url: endpoint.appending("chat/completions"), body: body, apiKey: apiKey)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AIHTTP.stream(session: session, request: request) { line in
            guard line.hasPrefix("data:") else { return .skip }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                return .done
            }
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return .skip }
            if let failure = chunk.error {
                throw AIError.http(status: 200, message: failure.message ?? "")
            }
            guard let text = chunk.choices?.first?.delta?.content, !text.isEmpty else { return .skip }
            return .text(text)
        }
    }
}
