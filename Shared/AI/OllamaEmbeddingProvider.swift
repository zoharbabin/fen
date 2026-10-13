import Foundation

/// Embeds text with a model served by Ollama on this Mac, for the search index (issue #35).
/// The address must be loopback, so text never leaves the device. A remote address is refused.
public final class OllamaEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public static let defaultAddress = OllamaProvider.defaultAddress
    public static let defaultModel = "embeddinggemma"
    /// EmbeddingGemma's output size. A vector of another size is dropped, not stored.
    public static let defaultDimension = 768

    public let id: String
    public let dimension: Int
    public let runsOnDevice = true
    /// On the 16-query set in `OllamaEmbeddingProviderTests`, right answers scored 0.40 or more and
    /// 90% of wrong ones scored under 0.32.
    public let similarityFloor: Float = 0.35

    private let endpoint: AIEndpoint
    private let model: String
    private let session: URLSession

    public init(
        address: String = OllamaEmbeddingProvider.defaultAddress,
        model: String = OllamaEmbeddingProvider.defaultModel,
        dimension: Int = OllamaEmbeddingProvider.defaultDimension
    ) throws {
        let endpoint = try AIEndpoint(address)
        guard endpoint.isLoopback else { throw AIError.notLoopback(host: endpoint.host) }
        self.endpoint = endpoint
        self.model = model
        self.dimension = dimension
        id = "ollama.\(model)"
        session = AIHTTP.makeSession()
    }

    private struct Body: Encodable {
        let model: String
        let input: String
    }

    private struct Reply: Decodable {
        let embeddings: [[Float]]?
        let error: String?
    }

    /// `true` when Ollama answers and has the model. Blocks for at most two seconds, and only
    /// off the main actor: the index asks once, before its first job.
    public var isAvailable: Bool {
        var request = URLRequest(url: endpoint.appending("api/show"), timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["model": model])
        let done = DispatchSemaphore(value: 0)
        let found = ResultBox()
        session.dataTask(with: request) { _, response, _ in
            found.value = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return found.value
    }

    public func embed(_ text: String) async throws -> [Float] {
        let request = try AIHTTP.jsonRequest(
            url: endpoint.appending("api/embed"),
            body: Body(model: model, input: text)
        )
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EmbeddingTextError.noVector }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let vector = reply.embeddings?.first, vector.count == dimension else { throw EmbeddingTextError.noVector }
        return vector
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
