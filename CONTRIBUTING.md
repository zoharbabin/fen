# Contributing to Fen

Thanks for helping. Issues, bug reports and pull requests are all welcome. Read the [Code of Conduct](CODE_OF_CONDUCT.md) first.

## Getting started

```sh
git clone https://github.com/zoharbabin/fen.git
cd fen
swift build
swift test --no-parallel
```

[README.md](README.md#project-layout) shows the project layout. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains why it's built this way. [docs/RELEASING.md](docs/RELEASING.md) covers signed builds.

## Before you open a pull request

Run the same checks CI runs:

```sh
swiftformat .
swiftlint
swift test --no-parallel
```

Use `--no-parallel`. Several suites drive a real `WKWebView`. Run in parallel, they fight over the pasteboard, temp files and WebView startup, and fail for no real reason. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#ci-and-releases).

If you touch the editor, the preview or scroll sync, also run the UI tests. CI doesn't run them yet.

```sh
xcodegen generate   # regenerates FenUITesting.xcodeproj from project.yml
xcodebuild test -scheme FenMacOSApp -project FenUITesting.xcodeproj \
  -destination 'platform=macOS'
```

CI runs only the jobs your change needs, so a docs-only PR runs just the link check. The job list is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#ci-and-releases). Every job writes a report to the run's Summary tab.

`.swiftformat` and `.swiftlint.yml` define the style rules. Don't silence them with inline disables unless you have a real reason, and say why in a comment.

## Coding style

- **Swift 6, strict concurrency.** New code compiles clean. Avoid `@unchecked Sendable` unless there's no other way.
- **SwiftUI first.** Use `NSViewRepresentable` or `UIViewRepresentable` only where SwiftUI has no answer, like the `WKWebView` preview. Keep those wrappers small.
- **Shared code lives in `Shared/` (the `FenCore` target).** If logic doesn't need AppKit or UIKit, put it there. Keep the `FenMacOS` and `FenIOS` targets thin: platform wiring only.
- **No force-unwraps or `try!` outside tests**, unless the type system or a check right before guarantees the value.
- **Match existing names and layout.** One primary type per file, named after the file.
- **Keep it fast.** Launch stays instant and typing never lags. Render large files incrementally or with a debounce. Don't ship a feature that makes the editor feel heavier.

## Keep Fen local-first

Fen reads and writes only the files and folders you grant it. Before and after a change that touches networking, run `grep -r "URLSession" Shared macOS iOS`. If you add a network call, say why in the PR. Don't add a CDN link: vendor the script or style instead. The full rules are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#no-proprietary-storage-format-and-no-cloud-ai-by-default).

## Tests

- Write new unit tests in `Tests/FenTests` with **Swift Testing** (`import Testing`, `@Test`), not XCTest.
- UI tests live in `UITests/`. Run `xcodegen generate` after you edit `project.yml`.
- New behavior needs a test. A bug fix needs a regression test that fails before the fix and passes after.
- Anything that ends up on screen needs a WebKit-driven test, not only a string check on the HTML. `Tests/FenTests/PreviewSchemeHandlerVerifyTest.swift` is the pattern.
- [docs/DEBUGGING.md](docs/DEBUGGING.md) shows how to rebuild Fen without testing a stale binary, and how to inspect the live preview with Safari's Web Inspector.

### Never wait with a fixed sleep

Don't use a fixed-duration `Task.sleep` to wait for something, in tests or in app code. Poll the real condition. `pollUntilTrue` in `Tests/FenTests/WebViewPreviewTestSupport.swift` does this. Pass it a JS string to poll `WKWebView` state, or a `() async throws -> Bool` closure to poll Swift state.

- **Poll a condition that matches what you wait for.** `document.readyState === 'complete'` doesn't mean `WKNavigationDelegate.didFinish` has run. WebKit sends delegate callbacks and page JS state over separate channels, and they can arrive out of order. Poll the native side's own result, such as a counter the callback increments.
- **To prove something did not happen**, don't sleep and check. Send a second, distinct signal and poll for that. `WKScriptMessageHandler` delivers messages for one `WKWebView` in post order, so once the second message arrives, any wrong effect of the first would already show.
- **A cancelable UI debounce is fine.** The 300 ms `Task.sleep` in `SplitEditorView.scheduleRender()` waits out an interval on purpose, so it doesn't re-render on every keystroke, and typing cancels it. The rule targets sleeps that guess how long something else takes.

## Commit messages

Follow the [standard git convention](http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html): a short, imperative summary line, a blank line, then detail if needed. Explain why, not what. The diff shows what.

## Pull requests

- Open an [issue](https://github.com/zoharbabin/fen/issues) first for anything beyond a small fix.
- Work on a branch. `master` is protected and needs a PR with a passing `✅ CI gate` check.
- Keep each PR to one logical change.
- Rebase onto `master` instead of merging `master` into your branch.
- Make sure `swift build`, `swift test --no-parallel`, `swiftformat .` and `swiftlint` are clean.
- Reference the issue in the PR, and update any doc that describes behavior you changed.

## Reporting bugs

Open a [GitHub issue](https://github.com/zoharbabin/fen/issues/new?template=bug_report.md) with:

- What you expected and what happened
- Your macOS or iOS version and Fen version (**Fen > About Fen**)
- Steps to reproduce, plus a sample `.md` file if the bug depends on content

Found a security problem? Don't open a public issue. Use [GitHub's private vulnerability reporting](https://github.com/zoharbabin/fen/security/advisories/new).

## Questions

Not sure where something belongs, or want to propose a bigger change before you write code? Open an [issue](https://github.com/zoharbabin/fen/issues) and we'll talk it through.
