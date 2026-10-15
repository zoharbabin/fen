import Foundation

/// Answers with a model you downloaded (issue #234): a Gemma 4 model run by llama.cpp inside
/// Fen's process. Like every provider it is reached only through `AIService`. It keeps content on
/// this device, so its destination is `.local`.
struct LlamaAnswerProvider: AIProvider {
    static let maxTokens = 1024
    static let temperature: Float = 0.6

    let model: ModelDescriptor
    let file: URL

    var destination: ModelDestination {
        .local
    }

    /// An iPhone or iPad throttles hard once it is serious. A Mac has fans, so it only stops at critical.
    static func refusesToRun(
        at state: ProcessInfo.ThermalState,
        on platform: ModelPlatform = .current
    ) -> Bool {
        switch state {
        case .critical: true
        case .serious: platform != .mac
        default: false
        }
    }

    func send(prompt: String, context: [AIContextItem]) -> AsyncThrowingStream<String, Error> {
        guard !Self.refusesToRun(at: ProcessInfo.processInfo.thermalState) else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.deviceTooHot) }
        }
        let text = LlamaPrompts.gemma4Chat(
            system: AIPromptBuilder.instructions,
            user: AIPromptBuilder.userMessage(prompt: prompt, context: context)
        )
        #if canImport(llama)
            let model = model, file = file
            return AsyncThrowingStream { continuation in
                let cancelled = CancelFlag()
                let task = Task {
                    do {
                        try await LlamaWork.run {
                            let engine = try LlamaEngineCache.shared.engine(for: model, file: file)
                            try engine.generate(
                                prompt: text,
                                maxTokens: Self.maxTokens,
                                temperature: Self.temperature,
                                shouldStop: { cancelled.isSet },
                                onText: { continuation.yield($0) }
                            )
                        }
                        continuation.finish()
                    } catch let error as LlamaError {
                        if case .promptTooLong = error {
                            continuation.finish(throwing: AIError.contextTooLarge)
                        } else {
                            continuation.finish(throwing: error)
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    cancelled.set()
                    task.cancel()
                }
            }
        #else
            return AsyncThrowingStream { continuation in
                _ = text
                continuation.finish(throwing: AIError.systemModelUnavailable("This build can't run downloaded models."))
            }
        #endif
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.withLock { value = true }
        }

        var isSet: Bool {
            lock.withLock { value }
        }
    }
}
