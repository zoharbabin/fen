# Working in this repo

Fen is a native Swift/SwiftUI Markdown editor. Read [README.md](README.md) for what it is, [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for why it's built this way, and the [GitHub Issues list](https://github.com/zoharbabin/fen/issues) for what's next. This file is about how to work here: checks, procedure, tone.

## Before every commit

```sh
swiftformat .
swiftlint
swift test --no-parallel
```

Run all three. CI runs the same checks (`.github/workflows/ci.yml`). Use `--no-parallel`: several suites drive a real `WKWebView`, and running them concurrently contends for the system pasteboard, temp files and WebView startup. That produces false failures that vanish on a serial rerun. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#ci-and-releases).

If you touch the editor, preview or scroll sync, also run the UI tests locally. CI doesn't run them yet:

```sh
xcodegen generate                 # regenerate FenUITesting.xcodeproj from project.yml
xcodebuild test -scheme FenMacOSApp -project FenUITesting.xcodeproj \
  -destination 'platform=macOS'
```

Full command reference: [CONTRIBUTING.md](CONTRIBUTING.md).

## Keep docs synced to the codebase

Docs describe current behavior. Treat every doc edit as a chance to re-verify the claim, not just restate it.

- **Verify against the source of truth.** Check the code, `gh release list` and `gh secret list` before you trust an issue checkbox. A checked box that doesn't match reality hides work that still needs doing.
- **Update the doc in the same change that changes the behavior it describes.** Same PR, same commit where practical.
- **Anchor to stable things:** file paths, function names, CLI flags. Link to the section that already covers a topic (README, ARCHITECTURE, RELEASING, CONTRIBUTING) instead of restating it.
- **Favor facts that stay true:** architecture, interfaces, commands. Leave out version numbers, line counts and commit counts. They drift the moment you write them.
- **The changelog is [GitHub Releases](https://github.com/zoharbabin/fen/releases).** Every release needs hand-written notes. `release.yml` sets `generate_release_notes: true` as a fallback, but it only lists merged PR titles and skips the why. Before you call a release done, run `gh release view <tag> --json body -q .body`. If it's only that list or a bare `**Full Changelog**: vX...vY` link, write real notes and run `gh release edit <tag> --notes-file`. The format is in [docs/RELEASING.md](docs/RELEASING.md#write-the-release-notes-by-hand).

## Writing style

Second person, active voice, contractions welcome. Short, direct sentences beat long compound ones. Address the reader as "you" and call the project "we." Avoid: *leverage, utilize, synergy, seamless, robust, innovative, cutting-edge, game-changing, simply, easy*. Don't use em dashes.

This applies to README, CONTRIBUTING, RELEASING, CODE_OF_CONDUCT, GitHub issue bodies and the `site/` landing page. Code comments, commit messages and the MIT license text keep their own conventions.

Write Markdown as flowing prose. Keep each paragraph on one source line and let the editor soft-wrap it. Use a trailing double-space line break only for a real mid-paragraph break. Keep tables, task lists, fenced code blocks (with a language tag) and footnotes spec-compliant GFM. `assets/demo.md` exercises the full syntax Fen's renderer supports, so check new Markdown features against it.

## Security & compliance

Build and review every change to the strictest reasonable bar: enterprise and regulated-industry standards, not "good enough for a hobby app".

### Trust model: local-first

Fen reads and writes only inside the files and folders you grant: documents you open and workspaces you add. Every other feature stays fully offline.

Before and after any change that touches networking, run:

```sh
grep -rn "URLSession\|NWListener\|Process()" Shared macOS iOS
```

Document the reason for any new network call in the PR description and in the table below. The table is the complete list of network paths. Each one starts with a choice you make.

| Feature | Code | Connects to | Your gate |
|---|---|---|---|
| GeoJSON and TopoJSON maps | `Shared/Rendering/HTMLComposer+GeoJSONMap.swift` (Leaflet inside the preview `WKWebView`, not `URLSession`) | `tile.openstreetmap.org` for basemap tiles | `htmlGeoJSONMaps` preference, off by default. [Why this is the one carve-out](docs/ARCHITECTURE.md#the-geojsontopojson-map-preference-is-the-one-deliberate-exception) |
| Update check | `Shared/Updates/UpdateChecker.swift` | `api.github.com` (newest release), no redirects | You start it from the menu. [Details](docs/ARCHITECTURE.md#check-for-updates-sparkle-installs-a-build-you-asked-for) |
| In-app updates | `macOS/AppUpdater.swift` (Sparkle, the only third-party framework that talks to the network) | The feed and zip under `github.com/zoharbabin/fen/releases/` | You choose Check for Updates. `UpdateChannel` refuses to start Sparkle without a public key. |
| GitHub sync | `Shared/Sync/GitHubAPI.swift` (pull requests, and on iOS the repository's files), `Shared/Sync/GitSync.swift` (through `GitTool`) | `api.github.com` only, no redirects, plus the git remote you cloned from | A workspace you cloned from GitHub. [Details](docs/ARCHITECTURE.md#github-sync-clone-pull-and-push-with-the-git-you-have-a-scoped-token-in-the-keychain) |
| AI providers | `Shared/AI/` | The endpoints you add | You add the provider. [Details](docs/ARCHITECTURE.md#ai-providers-one-gate-no-provider-reachable-around-it) |
| Model downloads | `Shared/AI/ModelStore.swift` | The https hosts in the catalog entry | You confirm the host and size shown in `ModelDescriptor.consentText` (Settings > AI > On-device models). [Details](docs/ARCHITECTURE.md#downloaded-models-a-confirmed-download-a-checked-file-an-engine-inside-fen) |
| MCP server | `Shared/MCP/MCPServer.swift` | Nothing outbound. It listens on `127.0.0.1` only. | Off until you turn it on. [Details](docs/ARCHITECTURE.md#mcp-server-a-loopback-listener-off-by-default-reads-through-the-index-writes-through-the-gate) |

Where each API may appear:

| API | Allowed only in |
|---|---|
| `URLSession` | `Shared/AI/`, `Shared/Sync/GitHubAPI.swift`, `Shared/Updates/UpdateChecker.swift`. `HTMLComposer+GeoJSONMap.swift` mentions it in a comment only. |
| `NWListener` | `Shared/MCP/MCPServer.swift` |
| `Process()` | `Shared/Workspaces/Agents/GitTool.swift` |

Rules for the exceptions:

- **`GitTool` runs `git`** for [agent branches](docs/ARCHITECTURE.md#agent-branches-an-mcp-client-commits-to-its-own-branch-your-checkout-stays-put) and for the read-only diff behind [conflict checks](docs/ARCHITECTURE.md#conflict-checks-whats-new-against-whats-near-a-cheap-pass-first-a-fix-only-through-the-gate). Those uses never touch your `HEAD`, index or working tree. GitHub sync (`Shared/Sync/GitSync.swift`) also runs through `GitTool`. It's the one place that updates your working tree or commits, and only when you pull or sync.
- **Model downloads are `ModelStore` alone.** It accepts https only, follows a redirect only to the hosts in the catalog entry, and installs a file only if its size and SHA-256 match the catalog.
- **Adding a model:** add it to `ModelCatalog` with a pinned commit, size, hash and license text under `LICENSE/`. Weights never go in the app package (`DownloadedProviderTests` and `release.yml` check).
- **llama.cpp** (`Shared/AI/Llama/`) reads a local file and opens no connection.
- **Reach a model only through `AIService`.** Never make a provider `public`.

### Everything else

- **Zero third-party runtime network loads.** Every script and style ships vendored inside the app. highlight.js loads from `Shared/Resources/Highlight/`. Mermaid, MathJax, Leaflet and topojson-client load from `Shared/Resources/Extensions/`. All load through `HTMLComposer`, never from a CDN ([why](docs/ARCHITECTURE.md#every-third-party-resource-is-vendored-not-loaded-from-a-cdn)). If a feature needs a remote script, style or font, vendor it before you merge. Don't add a CDN reference, even behind an opt-in preference. The map preference above is the only exception.
- **Ship every distributed build signed and notarized.** `release.yml` does this for tagged releases (see [docs/RELEASING.md](docs/RELEASING.md)). Keep every `Fen.app.zip` on the Releases page signed this way.
- **Keep entitlements to the minimum the feature needs.** `macOS/Fen.entitlements` grants only `com.apple.security.cs.allow-jit`. Justify each addition in the PR. An enterprise security review asks the same question.
- **`PathGate` (`Shared/Workspaces/PathGate.swift`) is the one containment check between a file path and the local filesystem.** `PreviewSchemeHandler` and every workspace read go through it. See [Preview](docs/ARCHITECTURE.md#preview-a-custom-url-scheme-not-loadhtmlstringbaseurl) and [Workspaces](docs/ARCHITECTURE.md#workspaces-any-number-of-granted-folders). Pair any change to it with a test proving that traversal attempts still fail: `../`, symlinks, sibling folders that share a name prefix, and absolute paths.
- **Keep signing and notarization credentials only as GitHub Actions secrets** (`gh secret list`). Keep Dependabot and secret-scanning push protection on.

## Development procedure

1. **Open a [GitHub issue](https://github.com/zoharbabin/fen/issues)** for anything beyond a trivial fix, bug or feature. Check the open issues first to avoid a duplicate.
2. **Branch, then PR.** `master` is protected: it requires a PR and a passing `✅ CI gate` check (it passes when every job that ran passed), including for admins.
3. **Every PR needs** `swift build`, `swift test --no-parallel`, `swiftformat .` and `swiftlint` clean. CI enforces this. Pair new behavior with a test. Pair a bug fix with a regression test that fails before the fix and passes after. See [CONTRIBUTING.md](CONTRIBUTING.md#tests).
4. **Run the UI tests yourself for anything touching `SplitEditorView`, the editor or the preview.** `UITests/` exercises real window and document interaction, and `ci.yml` doesn't run it. Say in the PR description that you ran them.
5. **Close the loop.** Reference the issue in the PR. Close the issue, or check its acceptance-criteria boxes, in the same PR when the change finishes it. A sub-issue updates its parent's progress tracker automatically.
6. **Milestones match releases.** See [docs/RELEASING.md](docs/RELEASING.md#milestones-match-releases).

## Never use a fixed-duration sleep to synchronize

This applies to tests and app code. [CONTRIBUTING.md](CONTRIBUTING.md#tests) has the rule, the shared `pollUntilTrue` helper, the technique for proving absence, and the one exception: a cancelable UI debounce, which waits out an interval on purpose.

## Verify end to end, not just unit-level

A unit test on `MarkdownRenderer`'s HTML string can pass while the feature is visibly broken. CSS layout, JS-driven DOM changes and WebKit quirks live below what a string assertion sees. For every capability you build or fix, write a test that exercises it the way a user would, and look at the running app before you call it done.

- **Add a WebKit-driven test for anything that ends up on screen.** `Tests/FenTests/PreviewSchemeHandlerVerifyTest.swift` is the pattern: load real composed HTML through `PreviewSchemeHandler` into a `WKWebView`, then assert on `getBoundingClientRect()`, computed styles or DOM shape, not on `result.html.contains(...)`. That's what caught the task-list checkbox bug: the raw HTML looked fine, but the checkbox and its text rendered on separate lines once real CSS applied.
- **Prove the regression test exercises the bug.** Stash the fix, rerun the new test and confirm it fails. Restore the fix and confirm it passes. A test that passes both ways tests nothing.
- **Build and launch the real app for anything with a visible surface** (rendering, layout, a preference, a UI flow). Run `xcodegen generate`, then `xcodebuild -project FenUITesting.xcodeproj -scheme FenMacOSApp -destination 'platform=macOS' build`, then `open -a <built .app path> <test file>`. Look at a screenshot, or read one back through the WebKit test's `takeSnapshot(configuration:)`. Don't infer correctness from green tests alone.
- **State what you verified and how** (test output, screenshot, launched app) separately from what you infer.
