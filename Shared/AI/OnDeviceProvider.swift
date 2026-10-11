import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Whether the model that ships with the OS can run here.
public enum OnDeviceModelAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public static var current: OnDeviceModelAvailability {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return .available
                case let .unavailable(reason):
                    switch reason {
                    case .deviceNotEligible:
                        return .unavailable("This device doesn't support Apple Intelligence.")
                    case .appleIntelligenceNotEnabled:
                        return .unavailable("Turn on Apple Intelligence in System Settings.")
                    case .modelNotReady:
                        return .unavailable("The on-device model is still downloading. Try again later.")
                    @unknown default:
                        return .unavailable("The on-device model is not available.")
                    }
                }
            }
        #endif
        return .unavailable("The on-device model needs macOS 26 or iOS 26.")
    }
}

/// The model that ships with the OS (Apple's FoundationModels). It runs inside Fen's process, needs
/// no install and no download, and sends nothing over the network (issue #4).
struct OnDeviceProvider: AIProvider {
    var destination: ModelDestination {
        .local
    }

    func send(prompt: String, context: [AIContextItem]) -> AsyncThrowingStream<String, Error> {
        let message = AIPromptBuilder.userMessage(prompt: prompt, context: context)
        #if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *) {
                return Self.stream(message)
            }
        #endif
        return AsyncThrowingStream { continuation in
            _ = message
            continuation.finish(throwing: AIError.systemModelUnavailable(
                "The on-device model needs macOS 26 or iOS 26."
            ))
        }
    }

    #if canImport(FoundationModels)
        @available(macOS 26.0, iOS 26.0, *)
        private static func stream(_ message: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    if case let .unavailable(reason) = OnDeviceModelAvailability.current {
                        continuation.finish(throwing: AIError.systemModelUnavailable(reason))
                        return
                    }
                    do {
                        let session = LanguageModelSession(instructions: AIPromptBuilder.instructions)
                        var sent = 0
                        // Each snapshot holds the whole answer so far. Yield only the new tail.
                        for try await snapshot in session.streamResponse(to: message) {
                            let text = snapshot.content
                            if text.count > sent {
                                continuation.yield(String(text.dropFirst(sent)))
                                sent = text.count
                            }
                        }
                        continuation.finish()
                    } catch let error as LanguageModelSession.GenerationError {
                        if case .exceededContextWindowSize = error {
                            continuation.finish(throwing: AIError.contextTooLarge)
                        } else {
                            continuation.finish(throwing: error)
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    #endif
}
