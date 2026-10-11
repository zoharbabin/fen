import Foundation

/// The HTTP side shared by the Ollama and OpenAI-compatible providers (issue #4). Every request
/// Fen makes to an AI provider goes through `stream`, so this file is the only place those network
/// calls live.
enum AIHTTP {
    /// What one line of a streaming answer means.
    enum Line {
        case text(String)
        case skip
        case done
    }

    /// An ephemeral session that never follows a redirect. A loopback endpoint can't bounce your
    /// content to another host, and a key is never replayed to one.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    static func jsonRequest(url: URL, body: some Encodable, apiKey: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Sends `request` and yields text as lines arrive. Cancelling the consumer cancels the request.
    static func stream(
        session: URLSession,
        request: URLRequest,
        interpret: @escaping @Sendable (String) throws -> Line
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    try await check(response, bytes: bytes)
                    lines: for try await line in bytes.lines {
                        switch try interpret(line) {
                        case let .text(piece): continuation.yield(piece)
                        case .skip: continue lines
                        case .done: break lines
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func check(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        if (300 ..< 400).contains(http.statusCode) {
            throw AIError.redirectRefused
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 2048 {
                    break
                }
            }
            throw AIError.http(status: http.statusCode, message: errorMessage(from: body))
        }
    }

    /// Reads `{"error": {"message": ...}}` (OpenAI), `{"error": "..."}` (Ollama), or the raw text.
    static func errorMessage(from body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let nested = object["error"] as? [String: Any], let message = nested["message"] as? String {
                return message
            }
            if let message = object["error"] as? String ?? object["message"] as? String {
                return message
            }
        }
        return String(bytes: body.prefix(300), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
