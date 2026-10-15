# Spike: which embedding model for search (issue #35)

Fen needs a model that turns text into vectors, so search can match meaning and not only words. It must run on your device, need no download and add no dependency. This spike compares the two models the OS gives us, then EmbeddingGemma through Ollama as an opt-in choice.

## Result

Fen uses Apple's sentence embedding (`NLEmbedding.sentenceEmbedding(for:)`) behind the `EmbeddingProvider` protocol, one model per language the OS covers (issue #234, see [More languages](#more-languages-issue-234)). Search works by words alone for any text the model can't read. You can also download a model that covers 100+ languages in one space, see [Downloaded models](#downloaded-models-issue-234).

## What we measured

One Mac (Apple silicon, macOS 26), 12 short notes and 16 hand-labeled queries. Half of the queries share no word with their answer. The set is small: treat the numbers as a sanity check, not a benchmark. The data and the code are in `Tests/FenTests/SearchQualityTests.swift`. Run `FEN_SPIKE=1 swift test --no-parallel --filter SearchQualityTests` to print them again.

| | NLEmbedding sentence | NLContextualEmbedding (mean of token vectors) |
|---|---|---|
| Dimensions | 512 | 512 |
| Meaning-only MRR | 0.74 | 0.74 |
| Time per call | about 9 ms | about 13 ms |
| Cosine, right answers (median) | 0.29 | 0.81 |
| Cosine, wrong answers (median) | 0.11 | 0.76 |
| Needs a download | No | Only if its assets are missing (`requestAssets` uses the network) |
| Extra license or weights | None, part of the OS | None, part of the OS |

The contextual model ranks as well, but its scores for right and wrong answers sit close together, so no similarity cutoff can separate them. The sentence model spreads them out. It is also cheaper and never needs the network, which Fen's trust model rules out.

## The similarity floor

Matches below the floor are dropped from the meaning list. We swept it on the same set.

| Floor | Meaning-only MRR | Hybrid MRR |
|---|---|---|
| 0 | 0.74 | 0.83 |
| 0.10 | 0.73 | 0.83 |
| 0.15 (chosen) | 0.72 | 0.79 |
| 0.20 | 0.60 | 0.73 |
| 0.30 | 0.30 | 0.56 |
| 0.45 | 0.13 | 0.56 |

Words alone score 0.56. Hybrid ranking beats both halves at every floor up to 0.25. A floor of 0.15 trades a little on this tiny set for less noise in big workspaces, where there are more wrong chunks to match.

The floor does not reject nonsense. A query of unrelated words still keeps 5 of the 12 chunks above 0.15. Meaning search always finds the nearest notes. Results that match only by meaning are labeled "Similar meaning" in the list.

## Memory

Measured with `scripts/measure-embedding-memory.swift`. It runs one model per fresh process, embeds 3,000 chunks of 60 words each, and reads `phys_footprint` (the number Activity Monitor shows as "Memory") and `resident_size` from `task_info`. Build and run it:

```sh
swiftc -O scripts/measure-embedding-memory.swift -o /tmp/measure-embedding-memory
/tmp/measure-embedding-memory sentence 3000
/tmp/measure-embedding-memory contextual 3000
```

Machine: MacBook Pro, Apple M3 Pro, 36 GB, macOS 26.6.2 (25G83). Date: 2026-10-12. Three runs per model, release build. The process itself starts at 3.6 MB footprint and 9.4 MB resident. The table shows the growth over that start, as a range across the runs.

| Step | Sentence model (Fen uses this) | Contextual model |
|---|---|---|
| Footprint after load | +0.7 MB | +14.6 to +15.5 MB |
| Footprint after the first vector | +7.5 to +7.6 MB | +15.6 to +16.5 MB |
| Footprint after 3,000 chunks | +6.0 to +11.1 MB | +13.0 to +14.8 MB |
| Peak footprint while embedding | +11.3 to +11.6 MB | +16.5 to +17.5 MB |
| Resident size after 3,000 chunks | +39 to +40 MB | +73 to +74 MB |
| Time per 60-word chunk | 16.5 to 19.1 ms | 8.8 to 9.4 ms |

What this means:

- The sentence model adds about 12 MB of footprint at its peak, and about 40 MB of resident pages. It loads lazily, on the first vector.
- Footprint is not flat while embedding, and it fell again by the end in some runs. Treat the range, not one number, as the result.
- Without an `autoreleasepool` around each call, the same loop grew to 16 to 25 MB (sentence) and 182 MB (contextual) over 3,000 chunks. The growth came from the loop, not the model. We did not measure the footprint of a real indexing run in Fen.
- The 60-word chunks are slower than the short queries in the first table (about 9 ms for the sentence model). The 16.5 to 19.1 ms figure is close to the "about 21 ms per chunk" end-to-end number in Limits.
- The numbers cover this process only. Work the OS does for the model in other processes is not in them.
- We measured one machine and one OS build. We did not measure an iPhone or iPad, or a Mac with less memory.

## Limits

- Only languages the OS has a model for. Text in any other language gets no vector and is found by words.
- Indexing with the real model ran at about 21 ms per chunk, end to end (600 chunks in 12.5 s). A workspace of 100,000 chunks takes about 35 minutes in the background. Indexing waits in Low Power Mode and while background work is paused.
- One vector takes 516 bytes (512 bytes plus a 4-byte scale). 100,000 chunks take about 50 MB on disk and in memory.

## EmbeddingGemma through Ollama

You can pick EmbeddingGemma in Settings > AI > Search. It is the better model, and it runs on your Mac through [Ollama](https://ollama.com) (`ollama pull embeddinggemma`). Apple's model stays the default because it needs no setup. Ollama is the runtime: Fen has no Swift runtime for the model, and we add no dependency. The address must be loopback (`AIEndpoint.isLoopback`), so the text never leaves your Mac. Fen picks the model at launch, so a change needs a restart. Then the index rebuilds, because the provider id is part of the index signature. If Ollama isn't running, search uses words only.

Same 12 notes and 16 queries, same Mac. Run `FEN_LIVE_OLLAMA=1 swift test --no-parallel --filter OllamaEmbeddingProviderTests` to print them again.

| | EmbeddingGemma (Ollama) |
|---|---|
| Dimensions | 768 |
| Meaning-only MRR | 1.0 |
| Similarity floor | 0.35 |
| Time per note | about 41 ms |
| Memory | Held by Ollama, about 620 MB on disk. Not measured in RAM. |

We did not test the task prefixes the model card suggests, or text longer than the model's input limit. Search quality on a real workspace is not measured. The set is small, so treat 1.0 as "no miss on this set", not as a benchmark.

## More languages (issue #234)

On the Mac we measured (macOS 26.6), the OS has sentence models for English (512 dimensions), Spanish, French, German, Italian and Portuguese (640 each). It has none for Dutch, Chinese, Japanese, Korean, Russian, Arabic, Turkish, Hebrew, Hindi, Swedish, Polish or Ukrainian. Fen asks the OS at run time (`Locale.LanguageCode.isoLanguageCodes` with `NLEmbedding.currentSentenceEmbeddingRevision(for:)` and a non-nil model), so a newer OS adds languages with no code change. The provider id is `apple.nl.sentence`. It names no language. The index signature includes the list of spaces, so an OS that gains a language rebuilds the index once.

Each chunk is tagged with the language `NLLanguageRecognizer` finds. A query is tagged the same way and searched only among vectors of its language.

Data: `Tests/FenTests/MultilingualQualityCorpus.swift`, 12 notes and 16 hand-labeled queries per language. Run `FEN_SPIKE=1 swift test --no-parallel --filter MultilingualQualityTests` to print the numbers again. MRR is the mean reciprocal rank of the right note. "Hybrid" is words plus meaning, as the app ranks. The floor is the one in `AppleSentenceEmbeddingProvider.floors`.

| | es | fr | de | it | pt |
|---|---|---|---|---|---|
| Words-only MRR | 0.62 | 0.62 | 0.50 | 0.55 | 0.60 |
| Meaning-only MRR | 0.60 | 0.32 | 0.44 | 0.40 | 0.40 |
| Hybrid MRR | 0.71 | 0.70 | 0.60 | 0.67 | 0.61 |
| Queries read as the wrong language | 2 of 16 | 3 of 16 | 1 of 16 | 4 of 16 | 2 of 16 |
| Cosine, right answer (median) | 0.58 | 0.83 | 0.27 | 0.58 | 0.76 |
| Cosine, wrong answer (median) | 0.47 | 0.81 | 0.16 | 0.49 | 0.75 |
| Floor | 0.30 | 0.30 | 0.05 | 0.30 | 0.30 |

What this means:

- Hybrid beats words alone in all five languages. The gain is real but modest. Treat 16 queries per language as a sanity check, not a benchmark.
- French and Portuguese meaning-only search is weak. The cosines of right and wrong answers are almost the same (0.83 against 0.81 for French), so a floor can't separate them. Ranking still helps, because the fused list never did worse than words in these sets.
- German scores run low. A floor above 0.1 starts to drop right answers, so German uses 0.05.
- For Spanish, French, Italian and Portuguese, every floor from 0 to 0.35 gave the same result. We use 0.3.
- Short queries are the weak point. The recognizer reads one-word queries such as "tram", "faro" or "endpoints" as another language. Such a query finds nothing by meaning in that workspace and falls back to words. Hints and a language constraint on the recognizer moved 83 of 96 queries (the five sets plus the English set) to 84 correct, so we did not add them.
- A workspace that mixes all six languages plus one Dutch note: the right note is in the top 3 by meaning alone for 43 of 80 queries (the misread ones count as misses). The Dutch note is found by words.

Not measured: Catalan, Dutch and the other languages with no model; text that mixes languages inside one note; iPhone and iPad; the memory and time of the five extra models (we measured only the English one above). Classification and conflict checks stay English only.

## Downloaded models (issue #234)

Two embedding models you download in Settings > AI > On-device models, run inside Fen by llama.cpp (the choice is in [on-device-runtime.md](on-device-runtime.md)). Unlike Apple's models, each one puts every language in one vector space, so a query in one language can find a note in another.

| | EmbeddingGemma 2 (Q8_0) | Qwen3 Embedding 0.6B (Q8_0) |
|---|---|---|
| Size | 310 MB | 639 MB |
| Dimensions | 768 | 1024 |
| Languages | 100+ | 100+ |
| License | Apache-2.0 | Apache-2.0 |
| Similarity floor | 0.6 | 0.3 |
| Prompts | Documents: `title: none \| text: {text}`. Queries: `task: search result \| query: {q}` | Documents: plain. Queries: `Instruct: ...` then `Query:{q}` |

Data: the same 12 notes and 16 hand-labeled queries for English and for each of es, fr, de, it, pt that Apple's models were measured on (`QualityCorpus`, `MultilingualCorpus`), 96 queries in all. Run `FEN_SPIKE=1 FEN_MODEL_DIR=<folder with the two files> swift test --no-parallel --filter LlamaQualityTests` to print the numbers again. The tests skip when `FEN_MODEL_DIR` is unset.

Meaning-only MRR in the query's own language, at each model's floor:

| | en | es | fr | de | it | pt |
|---|---|---|---|---|---|---|
| Apple, meaning only | 0.74 | 0.60 | 0.32 | 0.44 | 0.40 | 0.40 |
| EmbeddingGemma 2 | 0.70 | 0.82 | 0.91 | 0.87 | 0.89 | 0.83 |
| Qwen3 Embedding 0.6B | 0.67 | 0.57 | 0.86 | 0.64 | 0.49 | 0.63 |

Over all 96 queries, with the notes of all six languages in one index:

| | Own-language MRR | Right note in the top 3 | Any-language MRR (the right note in any language counts) | Recall@6 across languages |
|---|---|---|---|---|
| EmbeddingGemma 2 | 0.84 | 90 of 96 | 0.98 | 0.85 |
| Qwen3 Embedding 0.6B | 0.64 | 79 of 96 | 0.96 | 0.79 |

A language with no Apple model. One Dutch note about a bike tyre among the 72 notes of the other languages:

| Query | EmbeddingGemma 2 | Qwen3 Embedding 0.6B |
|---|---|---|
| "flat tyre on my bicycle" (English) | rank 3 | rank 7 |
| "tengo un neumático desinflado" (Spanish) | rank 7 | rank 7 |
| "lekke band" (Dutch) | rank 3 | rank 1 |

What this means:

- EmbeddingGemma 2 is the better default. It is smaller and wins in every language we measured. We list it first in Settings.
- Both find notes across languages. When a note in any language counts as right, the MRR is 0.98 and 0.96. Only a downloaded model can do this. Apple's models can't, by design.
- Qwen3 Embedding is weaker on Spanish, Italian and Portuguese here. Its Italian MRR (0.49) is our lowest. Its cosines run lower (right answers have a median of 0.50, wrong ones 0.24), so its floor is 0.3.
- EmbeddingGemma 2's cosines are high for everything (right answers 0.74, wrong ones 0.60), so the floor is only a trim. Raising it past 0.65 starts to cost answers: at 0.7 cross-language recall falls from 0.85 to 0.43.
- EmbeddingGemma 2 puts the Dutch note in the top 3 for an English and for a Dutch query, and at rank 7 for a Spanish one. So a language with no Apple model still gets meaning search.
- EmbeddingGemma 2 must not run in fp16, and it needs `llama_model_n_embd_out` for its size (its hidden size is 512 and its output is 768). Qwen3 Embedding needs the end token added, because it pools the last token.

Changing the model rebuilds each workspace index, because the provider id is part of the index signature. Fen reads the choice at launch.

Not measured: Chinese, Japanese, Korean and the other languages with no hand-labeled set; notes longer than a chunk; hybrid (words plus meaning) ranking with these models; speed and memory on any device, including iPhone and iPad; indexing time for a large workspace. The sets are small, so treat the figures as a comparison between models, not as benchmarks. The Apple column is from the earlier runs above, on the same sets, but the comparison holds only on these sets.
