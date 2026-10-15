import Foundation

/// Keeps the loaded models, so a question or a search does not read gigabytes from disk again.
/// It holds at most one engine per role. Choosing another model or deleting one drops the old
/// engine and frees its memory.
final class LlamaEngineCache: @unchecked Sendable {
    static let shared = LlamaEngineCache()

    #if canImport(llama)
        private let lock = NSLock()
        private var engines: [ModelRole: (path: String, engine: LlamaEngine)] = [:]

        /// The Metal backend asserts or crashes at exit if a model is still loaded, so free them first.
        /// Exit handlers run last-in first-out. The Metal device registers its own at the first model
        /// load, so ours must come after that load or it runs too late.
        private static let freeAtExit: Void = {
            atexit { LlamaEngineCache.shared.evictAll() }
        }()

        func engine(for model: ModelDescriptor, file: URL) throws -> LlamaEngine {
            try lock.withLock {
                if let held = engines[model.role], held.path == file.path {
                    return held.engine
                }
                engines[model.role] = nil
                let mode: LlamaEngine.Mode = switch model.role {
                case .embedding: .embedding(contextLength: 2048)
                case .answer: .generation(contextLength: Self.answerContext)
                }
                let engine = try LlamaEngine(path: file, mode: mode)
                Self.freeAtExit
                engines[model.role] = (file.path, engine)
                return engine
            }
        }

        /// The memory a phone can spare is smaller, and a longer window costs memory.
        private static var answerContext: Int {
            #if os(iOS)
                4096
            #else
                8192
            #endif
        }

        func evict(path: String) {
            lock.withLock {
                for (role, held) in engines where held.path == path {
                    engines[role] = nil
                }
            }
        }

        func evictAll() {
            lock.withLock { engines.removeAll() }
        }
    #else
        func evict(path _: String) {}
    #endif
}

/// Runs blocking model work off the cooperative thread pool.
enum LlamaWork {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
