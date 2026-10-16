# Decision: the embedding model for search (issues #35 and #234)

Question: which model turns text into vectors, so search can match meaning and not only words? It must run on your device and add no dependency.

**Decision:**

| Choice | Role |
|---|---|
| Apple's sentence embedding (`NLEmbedding.sentenceEmbedding(for:)`), one model per language the OS covers | Default. Built in, no download, no setup. |
| EmbeddingGemma 2 or Qwen3 Embedding 0.6B, downloaded in Settings > AI > On-device models | Opt-in. All languages in one vector space. |
| EmbeddingGemma through Ollama on loopback | Opt-in. Settings > AI > Search. |

All sit behind the `EmbeddingProvider` protocol. `Shared/Search/EmbedderChoice.swift` picks one at launch. A change rebuilds each workspace index, because the provider id is part of the index signature. Text the model can't read is found by words only.

Code: `Shared/Search/AppleSentenceEmbeddingProvider.swift`, `Shared/AI/Llama/LlamaEmbeddingProvider.swift`, `Shared/AI/OllamaEmbeddingProvider.swift`.

## How to reproduce the numbers

All figures are dated measurements from 2026-10 on one Apple silicon Mac (macOS 26). They compare options on small hand-labeled sets. They aren't benchmarks and they will differ on other machines.

| Set | Test | Command |
|---|---|---|
| 12 English notes, 16 queries | `SearchQualityTests` | `FEN_SPIKE=1 swift test --no-parallel --filter SearchQualityTests` |
| Same size, es, fr, de, it, pt | `MultilingualQualityTests` | `FEN_SPIKE=1 swift test --no-parallel --filter MultilingualQualityTests` |
| All of the above on downloaded models | `LlamaQualityTests` | `FEN_SPIKE=1 FEN_MODEL_DIR=<folder with the model files> swift test --no-parallel --filter LlamaQualityTests` (skips without `FEN_MODEL_DIR`) |
| EmbeddingGemma through Ollama | `OllamaEmbeddingProviderTests` | `FEN_LIVE_OLLAMA=1 swift test --no-parallel --filter OllamaEmbeddingProviderTests` |

MRR below is the mean reciprocal rank of the right note. "Hybrid" is words plus meaning, as the app ranks.

## Apple's two models

Half of the English queries share no word with their answer.

| | `NLEmbedding` sentence (Fen uses this) | `NLContextualEmbedding` (mean of token vectors) |
|---|---|---|
| Meaning-only MRR | 0.74 | 0.74 |
| Time per call | about 9 ms | about 13 ms |
| Cosine, right answers (median) | 0.29 | 0.81 |
| Cosine, wrong answers (median) | 0.11 | 0.76 |
| Needs a download | No | Only if its assets are missing, and then it uses the network |

Why the sentence model: ranking is equal, but the contextual model's scores for right and wrong answers sit too close for any cutoff to separate them. The sentence model is also cheaper and never needs the network.

## The similarity floor

Matches below the floor are dropped from the meaning list. Sweep on the English set (words alone score 0.56):

| Floor | Meaning-only MRR | Hybrid MRR |
|---|---|---|
| 0 | 0.74 | 0.83 |
| 0.10 | 0.73 | 0.83 |
| 0.15 (chosen) | 0.72 | 0.79 |
| 0.20 | 0.60 | 0.73 |
| 0.30 | 0.30 | 0.56 |

Hybrid beats both halves at every floor up to 0.25. We chose 0.15 to trade a little on a tiny set for less noise in big workspaces.

The floor doesn't reject nonsense. Meaning search always finds the nearest notes, so results that match only by meaning are labeled "Similar meaning".

## Memory and cost of the Apple sentence model

Measured with `scripts/measure-embedding-memory.swift` (one model per fresh process, 3,000 chunks of 60 words, `phys_footprint`), release build, MacBook Pro M3 Pro, three runs.

| | Result |
|---|---|
| Footprint growth at peak | about 12 MB |
| Resident growth | about 40 MB |
| Time per 60-word chunk | 16.5 to 19.1 ms |
| Real indexing in Fen | about 21 ms per chunk end to end |
| One stored vector | 516 bytes (512 bytes plus a 4-byte scale) |

The model loads on the first vector. Footprint isn't flat while embedding, so read the range, not one number. Wrap each call in an `autoreleasepool`. Without it the same loop grew to 16 to 25 MB. We haven't measured the footprint of a real indexing run in Fen.

At 21 ms per chunk, 100,000 chunks take about 35 minutes in the background and about 50 MB on disk and in memory. Indexing waits in Low Power Mode and while background work is paused.

## EmbeddingGemma through Ollama

Runs on your Mac through [Ollama](https://ollama.com) (`ollama pull embeddinggemma`). The endpoint must be loopback (`AIEndpoint.isLoopback`), so text never leaves your Mac. If Ollama isn't running, search uses words only.

| | Result |
|---|---|
| Dimensions | 768 |
| Meaning-only MRR (English set) | 1.0, meaning no miss on this set |
| Similarity floor | 0.35 |
| Time per note | about 41 ms |

Not tested: the task prefixes from the model card, text longer than the input limit, and quality on a real workspace.

## More languages with Apple's models

The OS has sentence models for English (512 dimensions), Spanish, French, German, Italian and Portuguese (640 each), and none for Dutch, Chinese, Japanese, Korean, Russian, Arabic and others. Fen asks the OS at run time (`NLEmbedding.currentSentenceEmbeddingRevision(for:)`), so a newer OS adds languages with no code change. The index signature includes the list of spaces, so an OS that gains a language rebuilds the index once.

`NLLanguageRecognizer` tags each chunk. A query is tagged the same way and searched only among vectors of its language.

| | es | fr | de | it | pt |
|---|---|---|---|---|---|
| Words-only MRR | 0.62 | 0.62 | 0.50 | 0.55 | 0.60 |
| Meaning-only MRR | 0.60 | 0.32 | 0.44 | 0.40 | 0.40 |
| Hybrid MRR | 0.71 | 0.70 | 0.60 | 0.67 | 0.61 |
| Queries read as the wrong language | 2 of 16 | 3 of 16 | 1 of 16 | 4 of 16 | 2 of 16 |
| Floor (`AppleSentenceEmbeddingProvider.floors`) | 0.30 | 0.30 | 0.05 | 0.30 | 0.30 |

- Hybrid beats words alone in all five languages. The gain is real but modest.
- French and Portuguese meaning-only search is weak. Right and wrong answers have almost the same cosine, so a floor can't separate them. Ranking still helps.
- German cosines run low. A floor above 0.1 drops right answers, so German uses 0.05.
- For the other four, every floor from 0 to 0.35 gave the same result.
- Short queries are the weak point. The recognizer reads one-word queries as another language, so they fall back to words. Hints and a language constraint on the recognizer didn't help enough to add.

Not measured: languages with no model, text that mixes languages inside one note, and search quality on iPhone and iPad. Classification and conflict checks stay English only.

## Downloaded models

Run inside Fen by llama.cpp ([why](on-device-runtime.md)). Each puts every language in one vector space, so a query in one language can find a note in another.

| | EmbeddingGemma 2 (Q8_0) | Qwen3 Embedding 0.6B (Q8_0) |
|---|---|---|
| Size | 310 MB | 639 MB |
| Dimensions | 768 | 1024 |
| Languages | 100+ | 100+ |
| License | Apache-2.0 | Apache-2.0 |
| Similarity floor | 0.6 | 0.3 |

Meaning-only MRR in the query's own language:

| | en | es | fr | de | it | pt |
|---|---|---|---|---|---|---|
| Apple | 0.74 | 0.60 | 0.32 | 0.44 | 0.40 | 0.40 |
| EmbeddingGemma 2 | 0.70 | 0.82 | 0.91 | 0.87 | 0.89 | 0.83 |
| Qwen3 Embedding 0.6B | 0.67 | 0.57 | 0.86 | 0.64 | 0.49 | 0.63 |

All 96 queries against one index with the notes of all six languages:

| | Own-language MRR | Right note in top 3 | Any-language MRR | Recall@6 across languages |
|---|---|---|---|---|
| EmbeddingGemma 2 | 0.84 | 90 of 96 | 0.98 | 0.85 |
| Qwen3 Embedding 0.6B | 0.64 | 79 of 96 | 0.96 | 0.79 |

What this means:

- EmbeddingGemma 2 is the better default. It's smaller and wins in every language we measured. Settings lists it first.
- Both find notes across languages, which Apple's models can't do by design. A Dutch note about a bike tyre, a language with no Apple model, ranks in the top 3 for English and Dutch queries with EmbeddingGemma 2.
- Qwen3 Embedding's cosines run lower (right answers 0.50, wrong 0.24), so its floor is 0.3.
- EmbeddingGemma 2's cosines are high for everything (right 0.74, wrong 0.60), so its floor is only a trim. Above 0.65 it costs answers: at 0.7 cross-language recall falls from 0.85 to 0.43.
- Implementation notes. EmbeddingGemma 2 must not run in fp16, and it needs `llama_model_n_embd_out` for its size (hidden size 512, output 768). Qwen3 Embedding needs the end token added, because it pools the last token. Prompts live in `Shared/AI/Llama/LlamaPrompts.swift`.

Not measured: Chinese, Japanese, Korean and other languages with no labeled set, notes longer than a chunk, hybrid ranking with these models, and indexing time for a large workspace. Device load time and memory are in [on-device-runtime.md](on-device-runtime.md#measurements-on-real-devices).
