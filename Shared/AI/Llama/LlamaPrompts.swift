import Foundation

/// The text each downloaded model expects around its input (issue #234). Plain strings, so they
/// are tested without loading a model. Sources: the model cards of EmbeddingGemma 2, Qwen3
/// Embedding and Gemma 4.
enum LlamaPrompts {
    /// A note chunk, as the model sees it when it is stored in the index.
    static func document(_ text: String, title: String? = nil, kind: ModelKind) -> String {
        switch kind {
        case .embeddingGemma2: "title: \(title ?? "none") | text: \(text)"
        default: text
        }
    }

    /// A search query. The two embedding families train for a different task line.
    static func query(_ text: String, kind: ModelKind) -> String {
        switch kind {
        case .embeddingGemma2:
            "task: search result | query: \(text)"
        case .qwen3Embedding:
            "Instruct: Given a search query, retrieve notes that answer it\nQuery:\(text)"
        default:
            text
        }
    }

    /// One system and one user turn, ready for the model to write its turn. `<bos>` is parsed as
    /// the start token because the tokenizer reads special tokens in the prompt.
    static func gemma4Chat(system: String, user: String) -> String {
        "<bos><|turn>system\n\(system)<turn|>\n<|turn>user\n\(user)<turn|>\n<|turn>model\n"
    }
}
