# Spike: launch and typing latency proxies (issue #35)

Issue #35 asks for no regression in launch time and typing latency. We can't time a real launch or a real keystroke in CI. These headless tests time the work Fen puts on the main actor, which is what a user would feel as lag. They catch a regression of an order of magnitude. They don't replace a look at the running app.

## What the tests cover

| Test | What it times |
|---|---|
| `LaunchLatencyProxyTests` | `WorkspaceLibrary` init, `start()`, and the longest stretch where the main actor was blocked, with 1, 5 and 20 already-indexed workspaces of 1000 files. Also a cold first index and a listing-only run up to 8000 files. |
| `TypingLatencyProxyTests` | Per-key edit time and the highlight-apply gap in a 5000-line note, idle, with Live Preview on, and while three workspaces of 2000 files are listed and indexed. |

Not covered: process start, SwiftUI scene setup, the first window, document loading and WebKit.

## What we measured

One Mac (Apple silicon, macOS 26), run once with the machine otherwise idle. Treat the numbers as a sanity check. They differ between machines and between runs.

| Case | Result |
|---|---|
| `start()` with 20 workspaces x 1000 files | 26 to 31 ms |
| Longest main-actor gap after `start()`, 1 to 20 workspaces | 0 to 13 ms |
| Longest main-actor gap, 8000-file listing | 0 to 3 ms |
| Cold index of 20 x 1000 files, longest gap | 10 ms (all indexed in about 26 s, off the main actor) |
| Typing, 5000 lines, idle: edit + highlight gap | median 6.2, p95 7.0, max 8.9 ms |
| Typing while indexing 3 x 2000 files: edit + highlight gap | median 6.8, p95 7.5 ms |
| Longest main-actor block while indexing and typing | 26 ms |
| Typing with Live Preview on, 5000 lines | median 719, p95 790 ms per key |

Unchanged workspaces are not embedded again at launch (`embed calls 0`).

## Finding: Live Preview is slow in a long note

With Live Preview on, each key restyles the whole note, so the cost grows with its length. At 5000 lines a key takes about 0.7 s. Live Preview is off by default and labeled Experimental. Its test ceiling is loose (5 s) on purpose, so it guards against a larger regression and not against this cost. Restyling only the edited blocks would fix it. That is not done.

## What changed in the code

`WorkspaceSnapshot.documents` sorted every file path on the main actor each time the index asked for files. `WorkspaceIndexer` now sorts the changed files itself, off the main actor, and the library passes `unsortedDocuments`. Listing order is unchanged.

## Limits

The ceilings are loose: typing median 100 ms, p95 250 ms, max 1000 ms. A slower machine or a busy CI runner should still pass. A real regression should not.
