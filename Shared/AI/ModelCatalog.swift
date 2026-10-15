import Foundation

/// The models Fen can download (issue #234). Each entry pins one commit of one file, so the URL,
/// size and SHA-256 never move. Every set of weights here is Apache-2.0. The license text is in
/// `LICENSE/`. To add a model, read the commit, size and hash from the Hugging Face API
/// (`/api/models/<repo>?blobs=true`), then download the file once and check the hash yourself.
public enum ModelCatalog {
    private static let gib: Int64 = 1 << 30

    /// Hugging Face hands the file to its download network. These are the only hosts it may reach.
    private static let huggingFaceHosts = ["huggingface.co", "hf.co"]

    private static func huggingFace(_ repository: String, commit: String, file: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://huggingface.co/\(repository)/resolve/\(commit)/\(file)")!
    }

    public static let embeddingGemma2 = ModelDescriptor(
        id: "embeddinggemma-2-q8",
        displayName: "EmbeddingGemma 2 (Google)",
        url: huggingFace(
            "ggml-org/embeddinggemma-2-GGUF",
            commit: "bfcd298762cc34d0357ece5ebdd31791a3a374d8",
            file: "embeddinggemma-2-Q8_0.gguf"
        ),
        sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
        byteCount: 309_855_456,
        fileName: "embeddinggemma-2-Q8_0.gguf",
        licenseName: "Apache-2.0",
        kind: .embeddingGemma2,
        languages: "100+ languages, one shared space",
        embeddingDimension: 768,
        redirectHostSuffixes: huggingFaceHosts,
        minimumMemory: 3 * gib
    )

    public static let qwen3Embedding = ModelDescriptor(
        id: "qwen3-embedding-0.6b-q8",
        displayName: "Qwen3 Embedding 0.6B (Alibaba)",
        url: huggingFace(
            "Qwen/Qwen3-Embedding-0.6B-GGUF",
            commit: "370f27d7550e0def9b39c1f16d3fbaa13aa67728",
            file: "Qwen3-Embedding-0.6B-Q8_0.gguf"
        ),
        sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439",
        byteCount: 639_150_592,
        fileName: "Qwen3-Embedding-0.6B-Q8_0.gguf",
        licenseName: "Apache-2.0",
        kind: .qwen3Embedding,
        languages: "100+ languages, one shared space",
        embeddingDimension: 1024,
        redirectHostSuffixes: huggingFaceHosts,
        minimumMemory: 3 * gib
    )

    /// The smallest Gemma 4 answer model. Its 2-bit-heavy mix is the only one that fits a phone.
    public static let gemma4E2BMobile = ModelDescriptor(
        id: "gemma-4-e2b-mobile",
        displayName: "Gemma 4 E2B, small (Google)",
        url: huggingFace(
            "unsloth/gemma-4-E2B-it-qat-mobile-GGUF",
            commit: "46af839dc23aceb4b965ab640dae7fc1bea39bba",
            file: "gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf"
        ),
        sha256: "0a5bbc20f91f92da96ab4870fa71b356c45b8500a7b8b9c3e0eb48359b72da28",
        byteCount: 2_186_186_784,
        fileName: "gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf",
        licenseName: "Apache-2.0",
        kind: .gemma4,
        languages: "140+ languages",
        redirectHostSuffixes: huggingFaceHosts,
        minimumMemory: 6 * gib
    )

    public static let gemma4E2B = ModelDescriptor(
        id: "gemma-4-e2b-q4",
        displayName: "Gemma 4 E2B (Google)",
        url: huggingFace(
            "google/gemma-4-E2B-it-qat-q4_0-gguf",
            commit: "675cff42a74c774d6cb76f76d8eacb49b48c9b93",
            file: "gemma-4-E2B_q4_0-it.gguf"
        ),
        sha256: "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634",
        byteCount: 3_349_516_256,
        fileName: "gemma-4-E2B_q4_0-it.gguf",
        licenseName: "Apache-2.0",
        kind: .gemma4,
        languages: "140+ languages",
        redirectHostSuffixes: huggingFaceHosts,
        minimumMemory: 8 * gib,
        platforms: [.mac, .iPad]
    )

    public static let gemma4E4B = ModelDescriptor(
        id: "gemma-4-e4b-q4",
        displayName: "Gemma 4 E4B (Google)",
        url: huggingFace(
            "google/gemma-4-E4B-it-qat-q4_0-gguf",
            commit: "4b4a2c1d584be7264f87aac328a1bc739ce81b6c",
            file: "gemma-4-E4B_q4_0-it.gguf"
        ),
        sha256: "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee",
        byteCount: 5_154_941_280,
        fileName: "gemma-4-E4B_q4_0-it.gguf",
        licenseName: "Apache-2.0",
        kind: .gemma4,
        languages: "140+ languages",
        redirectHostSuffixes: huggingFaceHosts,
        minimumMemory: 12 * gib,
        platforms: [.mac]
    )

    public static let all = [embeddingGemma2, qwen3Embedding, gemma4E2BMobile, gemma4E2B, gemma4E4B]

    public static func models(for role: ModelRole) -> [ModelDescriptor] {
        all.filter { $0.role == role }
    }

    public static func model(id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }
}
