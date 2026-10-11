# Spike: which embedding model for search (issue #35)

Fen needs a model that turns text into vectors, so search can match meaning and not only words. It must run on your device, need no download and add no dependency. This spike compares the two models the OS gives us and records what we did not measure.

## Result

Fen uses Apple's sentence embedding (`NLEmbedding.sentenceEmbedding(for: .english)`) behind the `EmbeddingProvider` protocol. Search works by words alone for any text the model can't read.

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

## Limits

- English only. Text in another language gets no vector and is found by words.
- Indexing with the real model ran at about 21 ms per chunk, end to end (600 chunks in 12.5 s). A workspace of 100,000 chunks takes about 35 minutes in the background. Indexing waits in Low Power Mode and while background work is paused.
- One vector takes 516 bytes (512 bytes plus a 4-byte scale). 100,000 chunks take about 50 MB on disk and in memory.

## Not measured: EmbeddingGemma

The roadmap named EmbeddingGemma as a candidate. We did not run it. Fen has no Swift runtime for it (no LiteRT or Core ML conversion in the dependencies), and we keep dependencies minimal. The `EmbeddingProvider` protocol and the index signature are ready for it: a provider with a new `id` rebuilds the index. Measuring it needs a runtime decision first, and that belongs in its own issue.
