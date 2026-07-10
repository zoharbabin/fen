# Contributing to Fen

Thanks for considering a contribution. Fen is a small, focused project — your issues, bug reports, and pull requests are all welcome. Read our [Code of Conduct](CODE_OF_CONDUCT.md) before you jump in.

## Getting started

```sh
git clone https://github.com/zoharbabin/fen.git
cd fen
swift build
swift test
```

See [README.md](README.md) for project layout and [docs/RELEASING.md](docs/RELEASING.md) for how signed builds get cut.

## Before you open a pull request

Run these locally — they're the same checks CI runs:

```sh
swiftformat .
swiftlint
swift test
```

`.swiftformat` and `.swiftlint.yml` at the repo root define the rules; don't fight them with inline disables unless there's a real reason, and leave a comment explaining it when you do.

## Coding style

- **Swift 6, strict concurrency.** New code should compile clean under the settings in `Package.swift` — no `@unchecked Sendable` unless there's no reasonable alternative.
- **SwiftUI-first.** Prefer declarative view composition over imperative AppKit/UIKit calls; drop down to `NSViewRepresentable`/`UIViewRepresentable` only where SwiftUI doesn't cover it (e.g. the `WKWebView` preview). Keep such wrappers small.
- **Shared code lives in `FenCore`.** If a piece of logic doesn't genuinely need `AppKit` or `UIKit`, put it in `Shared/` so both platforms get it for free.
  - Keep the `FenMacOS` and `FeniOS` targets thin: platform-specific wiring only, no business logic.
- **No force-unwraps or `try!` in new code** outside of tests, unless the invariant is truly guaranteed by the type system or an immediately preceding check.
- **Match existing naming and file organization.** One primary type per file, file named after that type.
- **Performance guardrails, applied throughout:** keep launch instant and typing latency invisible; use incremental/debounced rendering for large files; no feature ships if it makes the editor feel heavier.

## Tests

- Use **Swift Testing** (`import Testing`, `@Test`), not XCTest, for new unit tests in `Tests/FenTests`.
- UI tests live in `UITests/` and run via the xcodegen-generated `FenUITesting.xcodeproj` (regenerate with `xcodegen generate` after editing `project.yml`).
- New behavior should come with a test. Bug fixes should come with a regression test that fails before the fix and passes after.
- **Never use a fixed-duration `Task.sleep` to wait for something to finish, in a test or in app code.** Poll the actual condition instead — `Tests/FenTests/WebViewPreviewTestSupport.swift`'s `pollUntilTrue` is the shared helper: pass it a JS string to poll `WKWebView` state, or a `() async throws -> Bool` closure to poll arbitrary Swift-side state (a delegate callback's own counter, a captured closure's result). A sleep long enough for CI's slower runner is either flaky (too short under load) or just a slow disguised version of the same bug (too long, and it's not testing that the condition ever actually became true — see `git log`'s history on `PreviewScrollRaceVerifyTest.swift` for a real example: a poll on a `requestAnimationFrame`-gated flag looked like a fix but silently timed out on every run, since `swift test` has no live display link to fire animation frames at all).
  - **Pick a condition that's genuinely correlated with the thing you're waiting for**, not just any observable state. `document.readyState === 'complete'` is not a valid proxy for "`WKNavigationDelegate.didFinish` has already run" — WebKit delivers navigation-delegate callbacks and in-page JS state over separate channels that can land out of order. When in doubt, poll the native side's own result (a counter incremented by the callback itself) rather than a JS-side signal you're hoping correlates with it.
  - **To prove an absence** (nothing happened), don't poll for a false condition or sleep-then-check — dispatch a second, real, distinguishable signal and poll for *that* one to arrive. `WKScriptMessageHandler` delivers messages for one `WKWebView` in post order, so once the second signal's message arrives, anything the first dispatch might have incorrectly triggered would already be visible.
  - **A cancelable UI debounce is not this anti-pattern.** `SplitEditorView.scheduleRender()`'s 300ms `Task.sleep` before a live-render-on-typing pass is deliberately waiting out a fixed interval as the actual desired behavior (don't re-render every keystroke), and cancels cleanly if the user keeps typing — it isn't standing in for a condition it should be polling instead. The rule targets sleeps used to *guess* how long some other async operation takes.

## Commit messages

Follow the [standard git convention](http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html): a short, imperative summary line, a blank line, then any needed detail in the body. Explain *why*, not just *what* — the diff already shows what changed.

## Pull requests

- Keep PRs focused — one logical change per PR is easier to review and easier to revert if something's wrong.
- Rebase onto `master` before opening the PR; keep history clean rather than merging `master` in repeatedly.
- Make sure `swift build`, `swift test`, `swiftformat`, and `swiftlint` are all clean before requesting review.

## Reporting bugs

Open a [GitHub issue](https://github.com/zoharbabin/fen/issues) with:

- What you expected vs. what happened
- macOS/iOS version and Fen version (`Fen → About Fen`)
- Steps to reproduce, and a sample `.md` file if the bug is content-specific

## Questions

Not sure where something belongs, or want to propose a bigger change before writing code? Open an [issue](https://github.com/zoharbabin/fen/issues) first — happy to talk it through.
