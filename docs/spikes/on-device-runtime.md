# Spike: which runtime for models you download (issue #234)

Fen needs one engine that runs a text embedding model and a chat model inside its own process, from files you download in Settings. No weights ship in the app. This spike records the choice.

## Result

Fen uses **llama.cpp** (build b11669) through its prebuilt `llama.xcframework`, declared as a SwiftPM `binaryTarget` in `Package.swift`. Models are single-file GGUF.

## How the options compare

| | llama.cpp | MLX Swift | Core ML | Apple Foundation Models (already in Fen) |
|---|---|---|---|---|
| License | MIT | MIT | Part of the OS | Part of the OS |
| Ships as | Prebuilt xcframework, one SwiftPM line | Swift packages built from source | Converted `.mlpackage` files | OS framework |
| macOS and iOS | Yes. Slices: macOS universal, iOS device | Apple Silicon only | Yes | Yes, on devices with Apple Intelligence |
| Model files | One GGUF file per model | Several safetensors and config files per model | One conversion per model, per Fen release | Not downloadable |
| Embedding models | Yes | Yes | Only models someone converted | No |
| `swift build` and `swift test` work | Yes | Needs Xcode to compile Metal shaders | Yes | Yes |
| Third-party code in the app | One 12 MB framework on iOS, 24 MB on macOS (universal) | Several packages | None | None |

We measured the llama.cpp column: the build, the framework sizes, and real models (below). We assessed the other columns from their documentation and did not build them. MLX Swift would cost more dependencies and a shader build step. Core ML would mean we convert and host every model. Apple's model can't be swapped or downloaded.

## The licenses

| Part | License | Where |
|---|---|---|
| llama.cpp | MIT | `LICENSE/llamacpp.txt` |
| Model weights (all five catalog entries) | Apache-2.0 | `LICENSE/model-weights-apache-2.0.txt` |

## What we verified

Run on a Mac with Apple Silicon, macOS 26.

| Check | Result |
|---|---|
| `swift build` and `swift test` with the xcframework | Pass |
| Xcode build of the macOS app | The framework is embedded in `Contents/Frameworks` and signed. The Quick Look extension finds it through its rpath. |
| `scripts/build-app.sh` (the release path) | Copies `llama.framework` next to Sparkle and signs it. The app launches. `release.yml` checks both. |
| iOS device build (`generic/platform=iOS`) | Passes. The framework is embedded. |
| iOS Simulator build | **Fails** with the framework. The binary has no simulator slice. Set `FEN_WITHOUT_LLAMA=1` to build without it. `ci.yml` and `scripts/test-share-inbox.sh` do. Downloaded models then report that the build can't run them. |
| Real EmbeddingGemma 2 and Qwen3 Embedding | Vectors have unit length and the right size. Numbers are in [embedding-model.md](embedding-model.md#downloaded-models-issue-234). |
| Real Gemma 4 E2B (Q4_0), E2B (mobile, Q2_K_XL) and E4B (Q4_0) | Each answers from a note in English and in Spanish, with no chat markup in the output. See below. |
| Stop a stream early, then ask again | The second answer works. |
| Network off | The tests that load these models open no connection. `ModelStore` is the only code in this feature that uses `URLSession`. |

Answer check (`Tests/FenTests/LlamaAnswerTests.swift`, run with `FEN_MODEL_DIR`): one short note that holds a code word. The model must return the word for an English question and for a Spanish one, with none of `<|channel`, `<turn|>`, `<bos>` in the text. All three models passed. A short answer took about 0.3 s once the model was loaded, and the first request about 2 to 4 s because it loads the file. This is one note and two questions per model. It shows that the prompt format and stop handling work. It does not measure answer quality.

## On a real iPhone and iPad

Run with `scripts/test-models-device.sh` on an iPhone 15 Pro Max (sold as 8 GB, reports 7655 MB) and an iPad Air 11-inch with the M2 (8 GB, reports 7643 MB), thermal state nominal. Each run is one model, one short prompt, so it shows that the model loads and answers. It is not a sustained-load or speed benchmark.

| Device | Model | Result |
|---|---|---|
| iPhone | EmbeddingGemma 2 | The first embedding took 0.7 s and the next 0.03 s, on the released v0.7.1 code. The first run after the file was copied took 12.9 s. Vectors have 768 values. Peak footprint 199 MB. |
| iPhone | Qwen3 Embedding 0.6B | The first embedding took 1.4 s, which includes loading the file. The next took 0.03 s. Vectors have 1024 values. Peak footprint 354 MB. |
| iPhone | Gemma 4 E2B, small (2-bit) | First text after 3.3 s, whole answer after 3.6 s. It answered the code-word question correctly. Peak footprint 274 MB. Run again on the released v0.7.1 code, with the 7 GiB gate. |
| iPad | EmbeddingGemma 2 | The first embedding took 9.5 s, which includes loading the file. The next took 0.02 s. Vectors have 768 values. Peak footprint 175 MB. |
| iPad | Qwen3 Embedding 0.6B | The first embedding took 0.9 s and the next 0.02 s. Vectors have 1024 values. Peak footprint 329 MB. |
| iPad | Gemma 4 E2B (Q4_0) | First text after 8.2 s, whole answer after 8.5 s. It answered the code-word question correctly. Peak footprint 250 MB. |

The footprint does not count the model file, which llama.cpp maps from disk. The mobile Gemma 4 loaded and ran without the increased-memory entitlement on this 8 GB phone.

A device reports less than its box size: 7655 MB for 8 GB. The catalog minimums use that figure (`ModelCatalog`), not 8 GiB, which would have turned away every 8 GB iPhone and iPad. A first version of the catalog used 8 GiB, and the run caught it.

## Gaps you should know about

- **Two devices were run.** An iPhone 15 Pro Max (8 GB) and an iPad Air with the M2 (8 GB). The memory minimums for other devices (3 GiB for the embedding models, 7 GiB for the Gemma 4 sizes that run on iPhone and iPad, 12 GiB for the largest) are estimates from file size and context length.
- **No iOS memory entitlement.** We did not add `com.apple.developer.kernel.increased-memory-limit` to `iOS/Fen.entitlements`. The mobile model ran without it on an 8 GB iPhone. Add it only if a model fails to load on a device we allow.
- **The 2 GB mobile Gemma 4 is the only answer model offered on iPhone.** Its quality is unmeasured beyond the check above. It is a 2-bit quant.
- **A download on iOS stops when the app is suspended.** It resumes from the saved part the next time you start it. We did not add a background `URLSession`, because a background session hands the file to the system and does not give the app the redirect check that `ModelStore` makes.
- **Heat.** `LlamaAnswerProvider` refuses to start at a "serious" thermal state on iPhone and iPad, and at "critical" on a Mac. We did not test it on hardware.
- **Cellular.** A download over cellular or a personal hotspot is off by default (`allowsExpensiveNetworkAccess`). Settings shows the switch on iOS.

## Other models we looked at

We started from Gemma 4 and EmbeddingGemma 2, and looked for one or two more options. We read model cards and repo listings. We ran only the models in the catalog. Scores below come from the model cards, not from our tests. The head-to-head numbers for the two embedding models are in [embedding-model.md](embedding-model.md#downloaded-models-issue-234).

| Model | Decision | Why |
|---|---|---|
| Qwen3 Embedding 0.6B | **In the catalog** | Apache-2.0, an official single-file GGUF, 1024 dimensions. Its card scores higher than EmbeddingGemma's on multilingual MTEB. In our test it is weaker on Spanish, Italian and Portuguese, so it stays an option and not the default. |
| Gemma 4 E2B (2-bit mobile), E2B and E4B | **In the catalog** | The sizes that fit an 8 GB iPhone, an 8 GB iPad and a Mac. See [what we verified](#what-we-verified). |
| EmbeddingGemma 2 in 4-bit (176 MB) | Not added | We found no quality numbers for 4-bit, and the Q8_0 file is only 310 MB. |
| Nomic Embed v2 MoE | Not added | Apache-2.0 with an official GGUF. The card shows it weaker than the models above. |
| Granite Embedding 97M multilingual | Not added | Apache-2.0, but only unofficial GGUFs. We pin files from the model's own repo or a first-party mirror. |
| Jina v5 text (nano, small) | Excluded | CC-BY-NC-4.0 does not allow commercial use. |
| Harrier OSS v1 270M | Not checked | No official GGUF. |
| BGE-M3 and multilingual E5 | Not checked | We did not look for GGUF files or scores. |
| Qwen3.5 4B and 2B (Q4_K_M) | Not added | Apache-2.0 and 201 languages. They think by default, and we did not test how to turn that off in `LlamaAnswerProvider`. Gemma 4 already covers the sizes we need. |
| Gemma 4 12B | Not added | About 7 GB at Q4_0 and needs 16 GB of memory. Only a Mac with that much could run it. |

Adding a model means a catalog entry with a pinned commit, size and hash, plus the checks in [the catalog rules](../ARCHITECTURE.md#downloaded-models-a-confirmed-download-a-checked-file-an-engine-inside-fen). Qwen3.5 4B is the first one to try if you want a second family of answer models.

## Why GGUF files from Hugging Face

Each catalog entry pins one file at one commit, with its SHA-256 and size (`Shared/AI/ModelCatalog.swift`). The URL redirects to a CDN (`*.hf.co`), so `ModelStore` follows a redirect only to the hosts the entry allows, and only over https. The confirmation text names the host and the size before anything connects. A wrong size or checksum deletes the download and stops the install (`ModelStoreTests`).
