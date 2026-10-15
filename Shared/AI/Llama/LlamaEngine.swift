#if canImport(llama)
    import Foundation
    import llama

    enum LlamaError: Error, LocalizedError, Equatable {
        case loadFailed
        case contextFailed
        case tokenizeFailed
        case decodeFailed(Int32)
        case promptTooLong(tokens: Int, limit: Int)
        case noEmbedding

        var errorDescription: String? {
            switch self {
            case .loadFailed: "The model file could not be loaded."
            case .contextFailed: "There isn't enough memory to run this model."
            case .tokenizeFailed: "The text could not be split into tokens."
            case let .decodeFailed(code): "The model stopped with error \(code)."
            case let .promptTooLong(tokens, limit): "The prompt has \(tokens) tokens and the model takes \(limit)."
            case .noEmbedding: "The model returned no embedding."
            }
        }
    }

    /// llama.cpp, wrapped for Fen (issue #234, docs/spikes/on-device-runtime.md). One engine holds
    /// one model file and one context, either for vectors or for text. llama.cpp contexts are not
    /// thread safe, so every call takes `lock`. Nothing here touches the network or the file system
    /// beyond reading the model file you pass in.
    final class LlamaEngine: @unchecked Sendable {
        enum Mode {
            case embedding(contextLength: Int)
            case generation(contextLength: Int)
        }

        private static let backend: Void = {
            // llama.cpp logs every tensor it loads. Fen prints none of it.
            llama_log_set({ _, _, _ in }, nil)
            llama_backend_init()
        }()

        private let lock = NSLock()
        private let model: OpaquePointer
        private let context: OpaquePointer
        private let vocab: OpaquePointer
        let contextLength: Int
        let dimension: Int

        init(path: URL, mode: Mode) throws {
            _ = Self.backend
            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = 999
            guard let model = llama_model_load_from_file(path.path, modelParams) else { throw LlamaError.loadFailed }

            var params = llama_context_default_params()
            switch mode {
            case let .embedding(length):
                params.n_ctx = UInt32(length)
                // A pooled embedding is one pass over the whole text, so the batch holds all of it.
                params.n_batch = UInt32(length)
                params.n_ubatch = UInt32(length)
                params.embeddings = true
                contextLength = length
            case let .generation(length):
                params.n_ctx = UInt32(length)
                params.n_batch = 512
                params.n_ubatch = 512
                contextLength = length
            }
            params.n_seq_max = 1
            params.no_perf = true
            let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            params.n_threads = threads
            params.n_threads_batch = threads
            guard let context = llama_init_from_model(model, params), let vocab = llama_model_get_vocab(model) else {
                llama_model_free(model)
                throw LlamaError.contextFailed
            }
            self.model = model
            self.context = context
            self.vocab = vocab
            // The vector a pooled run returns, which can differ from the hidden size (EmbeddingGemma 2).
            dimension = Int(llama_model_n_embd_out(model))
        }

        deinit {
            llama_free(context)
            llama_model_free(model)
        }

        // MARK: - Tokens

        func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [llama_token] {
            let utf8 = Array(text.utf8)
            var capacity = utf8.count + 16
            while true {
                var tokens = [llama_token](repeating: 0, count: capacity)
                let count = utf8.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress.map { base in
                        base.withMemoryRebound(to: CChar.self, capacity: utf8.count) {
                            llama_tokenize(
                                vocab,
                                $0,
                                Int32(utf8.count),
                                &tokens,
                                Int32(capacity),
                                addSpecial,
                                parseSpecial
                            )
                        }
                    } ?? 0
                }
                if count >= 0 {
                    return Array(tokens.prefix(Int(count)))
                }
                // A negative count is minus the size the call needed.
                guard Int(-count) > capacity else { throw LlamaError.tokenizeFailed }
                capacity = Int(-count)
            }
        }

        // MARK: - Embeddings

        /// A unit-length vector for `text`. Text longer than the context is cut at the end.
        /// `appendEndToken` is for models that pool on the last token (Qwen3 Embedding).
        func embed(_ text: String, appendEndToken: Bool) throws -> [Float] {
            try lock.withLock {
                var tokens = try tokenize(text, addSpecial: true, parseSpecial: false)
                let end = llama_vocab_eos(vocab)
                if appendEndToken, tokens.last != end {
                    if tokens.count >= contextLength {
                        tokens.removeLast(tokens.count - contextLength + 1)
                    }
                    tokens.append(end)
                } else if tokens.count > contextLength {
                    tokens.removeLast(tokens.count - contextLength)
                }
                guard !tokens.isEmpty else { throw LlamaError.tokenizeFailed }

                llama_memory_clear(llama_get_memory(context), true)
                var batch = llama_batch_init(Int32(tokens.count), 0, 1)
                defer { llama_batch_free(batch) }
                batch.n_tokens = Int32(tokens.count)
                for (index, token) in tokens.enumerated() {
                    batch.token[index] = token
                    batch.pos[index] = Int32(index)
                    batch.n_seq_id[index] = 1
                    batch.seq_id[index]?[0] = 0
                    batch.logits[index] = 1
                }
                let status = llama_decode(context, batch)
                guard status == 0 else { throw LlamaError.decodeFailed(status) }
                guard let raw = llama_get_embeddings_seq(context, 0) else { throw LlamaError.noEmbedding }
                let vector = Array(UnsafeBufferPointer(start: raw, count: dimension))
                return VectorCodec.normalized(vector) ?? vector
            }
        }

        // MARK: - Text

        /// Writes the reply to `prompt` piece by piece. `prompt` already holds the model's turn
        /// markers. Stops at the model's end-of-turn token, at `maxTokens`, or when `shouldStop` is true.
        func generate(
            prompt: String,
            maxTokens: Int,
            temperature: Float,
            shouldStop: () -> Bool,
            onText: (String) -> Void
        ) throws {
            try lock.withLock {
                var tokens = try tokenize(prompt, addSpecial: false, parseSpecial: true)
                let room = contextLength - maxTokens
                guard tokens.count <= room else {
                    throw LlamaError.promptTooLong(tokens: tokens.count, limit: max(room, 0))
                }
                llama_memory_clear(llama_get_memory(context), true)

                let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
                defer { llama_sampler_free(sampler) }
                llama_sampler_chain_add(sampler, llama_sampler_init_top_k(64))
                llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
                llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
                llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.max))

                // The prompt goes in one batch-sized slice at a time.
                var done = 0
                let slice = 512
                while done < tokens.count {
                    if shouldStop() {
                        return
                    }
                    let count = min(slice, tokens.count - done)
                    let status = tokens.withUnsafeMutableBufferPointer { buffer in
                        llama_decode(context, llama_batch_get_one(buffer.baseAddress! + done, Int32(count)))
                    }
                    guard status == 0 else { throw LlamaError.decodeFailed(status) }
                    done += count
                }

                var pending: [UInt8] = []
                for _ in 0 ..< maxTokens {
                    if shouldStop() {
                        return
                    }
                    var next = llama_sampler_sample(sampler, context, -1)
                    if llama_vocab_is_eog(vocab, next) {
                        break
                    }
                    pending += piece(next)
                    // A character can be split between two tokens. Wait until the bytes form one.
                    if let text = String(validating: pending, as: UTF8.self) {
                        if !text.isEmpty {
                            onText(text)
                        }
                        pending.removeAll(keepingCapacity: true)
                    } else if pending.count > 8 {
                        pending.removeAll(keepingCapacity: true)
                    }
                    let status = llama_decode(context, llama_batch_get_one(&next, 1))
                    guard status == 0 else { throw LlamaError.decodeFailed(status) }
                }
            }
        }

        private func piece(_ token: llama_token) -> [UInt8] {
            var buffer = [CChar](repeating: 0, count: 64)
            var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            if length < 0 {
                buffer = [CChar](repeating: 0, count: Int(-length))
                length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            }
            return buffer.prefix(max(Int(length), 0)).map { UInt8(bitPattern: $0) }
        }
    }
#endif
