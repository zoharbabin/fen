# Decision: headless proxies for launch and typing latency (issue #35)

Question: how do we guard launch time and typing latency when CI can't time a real launch or a real keystroke?

**Decision:** two headless test suites time the work Fen puts on the main actor, which is what a user feels as lag. They catch a regression of an order of magnitude. They don't replace a look at the running app.

| Test | What it times |
|---|---|
| `LaunchLatencyProxyTests` | `WorkspaceLibrary` init, `start()`, and the longest stretch where the main actor was blocked, with 1, 5 and 20 already-indexed workspaces of 1000 files. Also a cold first index and a listing-only run up to 8000 files. |
| `TypingLatencyProxyTests` | Per-key edit time and the highlight-apply gap in a 5000-line note: idle, with Live Preview on, and while three workspaces of 2000 files are listed and indexed. |

Not covered: process start, SwiftUI scene setup, the first window, document loading and WebKit.

Both suites print their numbers (`PERF launch ...`, `PERF typing ...`).

## Ceilings

The test ceilings are loose on purpose, so a slower machine or a busy CI runner still passes and a real regression doesn't.

| Test | Ceiling |
|---|---|
| Launch: library init, `start()`, main-actor gap | 500 ms each |
| Typing: median, p95, max per key | 100, 250, 1000 ms |
| Typing with Live Preview on, median | 5000 ms |

## Measurements

Dated 2026-10, one Apple silicon Mac (macOS 26), machine otherwise idle, run once. Numbers differ between machines and runs.

| Case | Result |
|---|---|
| `start()` with 20 workspaces of 1000 files | 26 to 31 ms |
| Longest main-actor gap after `start()`, 1 to 20 workspaces | 0 to 13 ms |
| Longest main-actor gap, 8000-file listing | 0 to 3 ms |
| Cold index of 20 workspaces of 1000 files, longest gap | 10 ms (all indexed in about 26 s, off the main actor) |
| Typing, 5000 lines, idle: edit plus highlight gap | median 6.2 ms, p95 7.0 ms, max 8.9 ms |
| Typing while indexing 3 workspaces of 2000 files | median 6.8 ms, p95 7.5 ms |
| Longest main-actor block while indexing and typing | 26 ms |
| Typing with Live Preview on, 5000 lines | median 719 ms, p95 790 ms per key |

Unchanged workspaces aren't embedded again at launch (`embed calls 0`).

## Known cost: Live Preview in a long note

With Live Preview on, each key restyles the whole note, so the cost grows with its length. At 5000 lines a key takes about 0.7 s. Live Preview is off by default and labeled Experimental in Settings. Its 5 s ceiling guards against a larger regression, not against this cost. Restyling only the edited blocks would fix it. That isn't done.

## What the measurements changed

`WorkspaceIndexer` sorts changed files off the main actor, and `WorkspaceLibrary` passes `unsortedDocuments`. Before, `WorkspaceSnapshot.documents` sorted every path on the main actor each time the index asked for files. Listing order is unchanged.
