# Debugging Fen's preview

Fen's preview is a real `WKWebView`. Layout drift, stale JS state and CSS conflicts show up as DOM and JS state, so inspect that instead of guessing from a screenshot. This page covers two tools: a script that guarantees you're running the build you just made, and Safari's Web Inspector attached to the running app.

## Rebuild and reinstall without fooling yourself

Two mistakes waste debugging time:

- `open -a` on an already running app only brings the old process to the front. It doesn't reload the binary.
- Forgetting to reinstall the `.app` after a fix means every later screenshot shows old code.

Use the script instead of a manual build, copy and open:

```sh
./scripts/dev-install.sh                    # build, install, relaunch fresh
./scripts/dev-install.sh path/to/file.md    # ...and open a specific file
```

It builds a debug `.app`, kills any running Fen, replaces `/Applications/Fen.app`, relaunches it, and checks by PID that the running binary is the one it just built.

## Inspect the live preview with Safari

`Shared/Preview/PreviewWebView.swift` sets `webView.isInspectable = true` in `#if DEBUG` builds only. Release builds never expose it.

1. In Safari, turn on **Settings → Advanced → Show features for web developers**. You do this once.
2. Run a debug build (`./scripts/dev-install.sh` builds one) and open the document that reproduces the bug.
3. In Safari, choose **Develop → [Your Mac] → Fen → (the preview page)**. The preview has no visible URL, so it's usually the only entry under Fen.
4. Run diagnostic JS in the Console tab. This example compares each `.fen-gutter-line` against its source leaf element, the same check `gutterStaysAlignedAtNonDefaultFontSize` in `Tests/FenTests/PreviewGutterVerifyTest.swift` automates:

```js
Array.from(document.querySelectorAll('.fen-gutter-line')).map(d => {
  const leaf = [...document.querySelectorAll('[data-sourcepos]:not(td):not(th)')]
    .find(el => el.getAttribute('data-sourcepos').split(':')[0] === d.textContent
      && !el.querySelector('[data-sourcepos]:not(td):not(th)'));
  return leaf ? d.getBoundingClientRect().top - leaf.getBoundingClientRect().top : 'no leaf';
});
```

A non-zero result is real drift in the running app, not a screenshot artifact.

## When a WebKit test passes but the app is still broken

A synthetic `WKWebView` test only reproduces the conditions you give it: default font size, default zoom, a fixed frame, one page load. The real app differs in these ways. Check each one:

| Difference | Why a test misses it |
|---|---|
| Non-default preferences | `Preferences.fontSize`, theme and appearance mode all feed CSS. A bug that only shows at a non-default font size is invisible to a test that never sets `fontSize`. |
| Zero-frame-then-resize lifecycle | `PreviewWebView.makeNSView` creates the `WKWebView` at `frame: .zero`. AppKit gives it its real size in a later layout pass. A test with a fixed frame skips that step. |
| Post-load scroll restore | `Coordinator.webView(_:didFinish:)` injects `scrollAssignmentJS` after every load to restore the saved scroll position. A test that loads once and reads back never runs it. |
| Full recompose and reload | `SplitEditorView.renderMarkdown()` rebuilds the whole HTML document and reloads the `WKWebView` on every `document.text` or `preferences.renderRevision` change. It isn't a live DOM patch. A test that never reloads skips this path. |

When a bug reproduces in the app but not in a test, treat the gap as your next lead. The Web Inspector is the fastest way to find which row applies.
