# Working in this repo

Fen is a native Swift/SwiftUI Markdown editor. Read [README.md](README.md) for what it is, [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for why it's built this way, and [docs/ROADMAP.md](docs/ROADMAP.md) for what's next. This file is about *how* to work here — checks, procedure, tone.

## Before every commit

```sh
swiftformat .
swiftlint
swift test
```

Run all three — they're the same checks CI runs (`.github/workflows/ci.yml`). If you touch the editor, preview, or scroll sync, also run the UI tests locally; CI doesn't cover them yet:

```sh
xcodegen generate                 # regenerate FenUITesting.xcodeproj from project.yml
xcodebuild test -scheme FenMacOSApp -project FenUITesting.xcodeproj \
  -destination 'platform=macOS'
```

Full command reference: [CONTRIBUTING.md](CONTRIBUTING.md).

## Keep docs synced to the codebase

Docs describe *current* behavior. Treat every doc edit as a chance to re-verify the claim, not just restate it:

- **Verify against the source of truth.** Check the code, `gh release list`, and `gh secret list` before trusting a roadmap checkbox — that catches drift like ROADMAP.md's signing-secrets item, which stayed marked incomplete for four releases after the secrets actually shipped.
- **Update the doc in the same change that changes the behavior it describes** — same PR, same commit where practical.
- **Anchor to stable things** — file paths, function names, CLI flags — and link to the section that already covers a topic (README/ROADMAP/RELEASING/CONTRIBUTING) instead of restating it.
- **Favor facts that stay true**: architecture, interfaces, commands. Version numbers, line counts, and commit counts drift the moment they're written, so leave them out.
- **The changelog lives in [GitHub Releases](https://github.com/zoharbabin/fen/releases)** — release notes generate from commits at tag time (see docs/RELEASING.md). That's the one and only changelog.

## Writing style

Second person, active voice, contractions welcome. Short, direct sentences beat long compound ones. Address the reader as "you"; call the project "we." Avoid: *leverage, utilize, synergy, seamless, robust, innovative, cutting-edge, game-changing, simply, easy*. This applies to README/ROADMAP/CONTRIBUTING/RELEASING/CODE_OF_CONDUCT and the `site/` landing page. Code comments, commit messages, and the MIT license text keep their own conventions.

Write Markdown as flowing prose: keep each paragraph on one logical source line (let the editor/viewer soft-wrap it), and reserve a trailing double-space line break for a genuine mid-paragraph break, not routine line wrapping. Keep tables, task lists, fenced code blocks (with a language tag), and footnotes spec-compliant GFM — `assets/demo.md` exercises the full syntax surface Fen's renderer supports, so check new Markdown features against it.

## Security & compliance

Build and review every change to the strictest reasonable bar — enterprise and regulated-industry standards, not just "good enough for a hobby app":

- **Fen's trust model is local-first: it reads and writes only the files you open.** Keep it that way — run `grep -r "URLSession" Shared macOS iOS` before and after a change that touches networking, and document the reason for any new network call in the PR description and in this section.
- **Fen has zero third-party runtime network loads — every script and style ships vendored inside the app.** highlight.js loads from `Shared/Resources/Highlight/`; Mermaid and MathJax load from `Shared/Resources/Extensions/` — both via `HTMLComposer`, not from a CDN — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#every-third-party-resource-is-vendored-not-loaded-from-a-cdn). If a feature needs a remote script, style, or font, vendor it the same way before merging; don't add a CDN reference, even behind an opt-in preference.
- **Ship every distributed build signed and notarized.** `release.yml` handles this automatically for tagged releases (see [docs/RELEASING.md](docs/RELEASING.md)) — keep every `Fen.app.zip` on the Releases page signed this way.
- **Keep entitlements to the minimum the feature needs.** `macOS/Fen.entitlements` currently grants only `com.apple.security.cs.allow-jit`. Justify each addition in the PR — it's the same question an enterprise security review will ask.
- **Keep `PreviewSchemeHandler`'s path check as the one gate between a Markdown file and the local filesystem.** See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#preview-a-custom-url-scheme-not-loadhtmlstringbaseurl). Pair any change to it with a test proving traversal attempts (`../`, symlinks, absolute paths) still fail.
- **Keep signing and notarization credentials exclusively as GitHub Actions secrets** (`gh secret list`), with Dependabot and secret-scanning push protection active on the repo.

## Development procedure

1. **Open a [GitHub issue](https://github.com/zoharbabin/fen/issues)** for anything beyond a trivial fix — bug report or feature proposal, checked against [docs/ROADMAP.md](docs/ROADMAP.md) first.
2. **Branch, then PR.** Work on a branch and open a PR for review, even though `master` has no branch protection enforcing it yet.
3. **Every PR needs**: `swift build`, `swift test`, `swiftformat .`, and `swiftlint` clean (CI enforces this). Pair new behavior with a test, and pair bug fixes with a regression test that fails before the fix and passes after. See [CONTRIBUTING.md](CONTRIBUTING.md#tests).
4. **Run UI tests yourself for anything touching `SplitEditorView`, the editor, or the preview** — `UITests/` exercises real window/document interaction and isn't wired into `ci.yml` yet. Mention in the PR description that you ran them.
5. **Close the loop.** Reference the issue in the PR, and flip ROADMAP.md's checkbox in the same PR when the change finishes a tracked item.

## Verify end-to-end, not just unit-level

A unit test on `MarkdownRenderer`'s HTML string output can pass while the feature is still visibly broken — CSS layout, JS-driven DOM changes, and WebKit rendering quirks live below what a string-content assertion can see. Every capability you build or fix needs a test that exercises it the way a real user would, plus a manual look at the running app before you call it done:

- **Add a WebKit-driven test, not just a renderer/string test, for anything that ends up on screen.** `Tests/FenTests/PreviewSchemeHandlerVerifyTest.swift` is the pattern: load real composed HTML through `PreviewSchemeHandler` into an actual `WKWebView`, then assert on `getBoundingClientRect()`, computed styles, or DOM shape — not on `result.html.contains(...)`. That's what caught the task-list checkbox bug: the renderer's raw HTML looked "fine" by string-matching, but the checkbox and its text rendered on separate lines once real CSS and layout applied.
- **Prove the regression test actually exercises the bug.** Stash the fix, rerun the new test, confirm it fails; restore the fix, confirm it passes. A test that passes both before and after your change isn't testing anything.
- **Build and launch the real app for anything with a visible surface** (rendering, layout, a new preference, a UI flow) before reporting the work as done: `xcodegen generate`, `xcodebuild -project FenUITesting.xcodeproj -scheme FenMacOSApp -destination 'platform=macOS' build`, then `open -a <built .app path> <test file>`. Take a screenshot or read one back through the WebKit test's `takeSnapshot(configuration:)` and actually look at it — don't infer correctness from green tests alone.
- **State plainly what you verified and how** (test output, screenshot, launched app) versus what you're inferring — per the global rule to back every progress claim with a tool result from the session.
