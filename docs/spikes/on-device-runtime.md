# Decision: the runtime for downloaded models (issue #234)

Question: which engine runs an embedding model and a chat model inside Fen's own process, from files you download in Settings? No weights ship in the app.

**Decision:** llama.cpp, through its prebuilt `llama.xcframework`. `Package.swift` declares it as a `binaryTarget` pinned to one build and checksum. Models are single-file GGUF.

Code: `Shared/AI/Llama/` (engine, providers), `Shared/AI/ModelCatalog.swift` (models), `Shared/AI/ModelStore.swift` (downloads). The rules for the catalog are in [ARCHITECTURE.md](../ARCHITECTURE.md#downloaded-models-a-confirmed-download-a-checked-file-an-engine-inside-fen). Embedding results are in [embedding-model.md](embedding-model.md#downloaded-models).

## How the options compare

We measured the llama.cpp column. We read the other columns from documentation and built none of them.

| | llama.cpp | MLX Swift | Core ML | Apple Foundation Models |
|---|---|---|---|---|
| License | MIT | MIT | Part of the OS | Part of the OS |
| Ships as | Prebuilt xcframework, one SwiftPM line | Swift packages built from source | Converted `.mlpackage` files | OS framework |
| Platforms | macOS and iOS | Apple Silicon only | macOS and iOS | Devices with Apple Intelligence |
| Model files | One GGUF per model | Several safetensors and config files | One conversion per model, per Fen release | Not downloadable |
| Embedding models | Yes | Yes | Only models someone converted | No |
| `swift build` and `swift test` | Work | Need Xcode for Metal shaders | Work | Work |

Why not the others: MLX Swift costs more dependencies and a shader build step. Core ML means we convert and host every model. Apple's model can't be swapped or downloaded.

## Licenses

| Part | License | Text |
|---|---|---|
| llama.cpp | MIT | `LICENSE/llamacpp.txt` |
| Model weights (every catalog entry) | Apache-2.0 | `LICENSE/model-weights-apache-2.0.txt` |

## What we checked

| Check | Result |
|---|---|
| `swift build` and `swift test` with the xcframework | Pass |
| `scripts/build-app.sh` (the release path) | Embeds `llama.framework` in `Contents/Frameworks` and signs it. `release.yml` verifies both. |
| iOS device build | Passes. The framework is embedded. |
| iOS Simulator build | Fails. The binary has no simulator slice. Set `FEN_WITHOUT_LLAMA=1` to build without it, as `ci.yml` does. Downloaded models then report that the build can't run them. |
| Answer check (`Tests/FenTests/LlamaAnswerTests.swift`, needs `FEN_MODEL_DIR`) | Every Gemma 4 catalog model returns a code word from a short note, for an English and a Spanish question, with no chat markup in the text. It shows that the prompt format and stop handling work. It doesn't measure answer quality. |
| Stop a stream early, then ask again | The second answer works. |
| Network | Tests that load these models open no connection. `ModelStore` is the only code in this feature that uses `URLSession`. |

## Measurements on real devices

Dated 2026-10, from `scripts/test-models-device.sh`. Both devices are sold as 8 GB, thermal state nominal. Each run is one model and one short prompt. It shows that the model loads and answers. It isn't a speed or sustained-load benchmark.

| Device | Model | First result | Next result | Peak footprint |
|---|---|---|---|---|
| iPhone 15 Pro Max | EmbeddingGemma 2 | 0.7 s | 0.03 s | 199 MB |
| iPhone 15 Pro Max | Qwen3 Embedding 0.6B | 1.4 s | 0.03 s | 354 MB |
| iPhone 15 Pro Max | Gemma 4 E2B mobile (2-bit) | First text 3.3 s, done 3.6 s | | 274 MB |
| iPad Air (M2) | EmbeddingGemma 2 | 9.5 s | 0.02 s | 175 MB |
| iPad Air (M2) | Qwen3 Embedding 0.6B | 0.9 s | 0.02 s | 329 MB |
| iPad Air (M2) | Gemma 4 E2B (Q4_0) | First text 8.2 s, done 8.5 s | | 250 MB |

The first embedding includes loading the file. The footprint doesn't count the model file, which llama.cpp maps from disk. The mobile Gemma 4 ran without the increased-memory entitlement.

A device reports less memory than its box size: 7655 MB for 8 GB. The catalog minimums use that figure (`ModelCatalog`), not 8 GiB, which would turn away every 8 GB iPhone and iPad.

## Open gaps

The on-device verification is tracked in [#237](https://github.com/zoharbabin/fen/issues/237).

- **Two devices only.** Minimums for other devices (3 GiB for embedding models, 7 GiB for the Gemma 4 sizes on iPhone and iPad, 12 GiB for the largest) are estimates from file size and context length.
- **No iOS memory entitlement.** `iOS/Fen.entitlements` has no `com.apple.developer.kernel.increased-memory-limit`. Add it only if a model fails to load on a device we allow.
- **Answer quality of the 2 GB mobile Gemma 4 is unmeasured.** It is a 2-bit quant and the only answer model offered on iPhone.
- **iOS downloads stop when the app is suspended** and resume from the saved part on the next start. We use no background `URLSession`, because it hands the file to the system and skips the redirect check `ModelStore` makes.
- **Heat.** `LlamaAnswerProvider` refuses to start at a "serious" thermal state on iPhone and iPad, and at "critical" on a Mac. Not tested on hardware.
- **Cellular.** Downloads over cellular or a personal hotspot are off by default (`allowsExpensiveNetworkAccess`). Settings shows the switch on iOS.

## Other models we looked at

We read model cards and repo listings and ran only the catalog models. Scores come from the cards, not from our tests.

| Model | Decision | Why |
|---|---|---|
| EmbeddingGemma 2 (Q8_0) | In the catalog, the default | Best in our language tests. |
| Qwen3 Embedding 0.6B | In the catalog | Apache-2.0, official single-file GGUF. Higher on the card's multilingual MTEB, but weaker on Spanish, Italian and Portuguese in our test. |
| Gemma 4 E2B (2-bit mobile), E2B, E4B | In the catalog | The sizes that fit an 8 GB iPhone, an 8 GB iPad and a Mac. |
| EmbeddingGemma 2 in 4-bit | Not added | No quality numbers for 4-bit. The Q8_0 file is only 310 MB. |
| Nomic Embed v2 MoE | Not added | Weaker than the models above on its card. |
| Granite Embedding 97M multilingual | Not added | Only unofficial GGUFs. We pin files from the model's own repo or a first-party mirror. |
| Jina v5 text | Excluded | CC-BY-NC-4.0 doesn't allow commercial use. |
| Qwen3.5 4B and 2B | Not added | They think by default, and we haven't tested turning that off in `LlamaAnswerProvider`. The first one to try for a second family of answer models. |
| Gemma 4 12B | Not added | About 7 GB at Q4_0 and needs 16 GB of memory. |
| Harrier OSS v1 270M, BGE-M3, multilingual E5 | Not checked | No official GGUF found, or not looked for. |

## Why GGUF files from Hugging Face

Each catalog entry pins one file at one commit, with its SHA-256 and size. The URL redirects to a CDN (`*.hf.co`). `ModelStore` follows a redirect only to the hosts the entry allows, and only over https. The confirmation text names the host and size before anything connects. A wrong size or checksum deletes the download and stops the install (`ModelStoreTests`).
