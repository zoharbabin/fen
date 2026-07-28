Debugging Fen's preview

Fen's preview is a real WKWebView, so bugs in it (layout drift, stale JS state, a
CSS rule interacting badly with a live style) usually need to be inspected as
DOM/JS state, not guessed at from a screenshot. This page covers the two tools
this repo has for that: a script that guarantees you're looking at the build
you just made, and Safari's Web Inspector attached to the running app.

Rebuild and reinstall without fooling yourself

Two mistakes cost real debugging time before this script existed: replacing
`/Applications/Fen.app` while an old instance of Fen was still running (`open
-a` on an already-running app just brings the existing process to the
foreground — it does not reload the binary), and forgetting to reinstall the
`.app` after a fix, so every later screenshot is still showing old code. Use
this instead of a manual build+copy+open sequence:

```sh
./scripts/dev-install.sh                    # build, install, relaunch fresh
./scripts/dev-install.sh path/to/file.md    # ...and open a specific file
```

It rebuilds a debug `.app`, kills any already-running Fen process, replaces
`/Applications/Fen.app`, relaunches it, and verifies by PID that what's now
running is the binary it just built — not a stale process you forgot was
still open.

Inspect the live preview with Safari's Web Inspector

`PreviewWebView.swift` sets `webView.isInspectable = true` in `#if DEBUG`
builds (never in Release, so this never ships), which lets Safari's Develop
menu attach to Fen's preview pane and read its actual DOM/JS state instead of
a rendered pixel screenshot.

1. In Safari, enable **Settings → Advanced → Show features for web
   developers** (only needed once).
2. Run a debug build (`./scripts/dev-install.sh` builds `CONFIG=debug`) and
   open the document that reproduces the bug.
3. In Safari's menu bar: **Develop → [Your Mac] → Fen → (the preview page)**.
   Fen's preview has no visible URL, so it's usually the only entry under the
   app's name.
4. Use the Console tab to run diagnostic JS directly against the live page —
   e.g. to compare a `.fen-gutter-line`'s painted position against its real
   leaf element, the same technique
   `Tests/FenTests/PreviewGutterVerifyTest.swift`'s
   `gutterStaysAlignedAtNonDefaultFontSize` test automates:

   ```js
   Array.from(document.querySelectorAll('.fen-gutter-line')).map(d => {
     const leaf = [...document.querySelectorAll('[data-sourcepos]:not(td):not(th)')]
       .find(el => el.getAttribute('data-sourcepos').split(':')[0] === d.textContent
         && !el.querySelector('[data-sourcepos]:not(td):not(th)'));
     return leaf ? d.getBoundingClientRect().top - leaf.getBoundingClientRect().top : 'no leaf';
   });
   ```

   A non-zero result here is real drift in the running app, not a rendering
   artifact of any particular screenshot.

Why a WebKit test can pass while the real app is still broken

A synthetic `WKWebView` test only reproduces the exact conditions you give
it — default font size, default zoom, a fixed frame, one page load with no
further mutation. The real app's preview differs in ways worth checking
explicitly whenever a synthetic test passes but the real app doesn't:

- **Non-default preferences.** `Preferences.fontSize`, theme, and appearance
  mode all feed CSS the default-configured test never exercises. A bug that
  only appears at a non-default font size (like the gutter double-zoom bug
  this doc's Web Inspector example was written for) is invisible in a test
  that never sets `fontSize`.
- **The zero-frame-then-resize lifecycle.** `PreviewWebView.makeNSView`
  constructs the real `WKWebView` at `frame: .zero`; AppKit only gives it its
  real split-view size on a later layout pass. A test that constructs its
  `WKWebView` at a fixed size skips that transition.
- **The post-load scroll-restore path.** `Coordinator.webView(_:didFinish:)`
  injects `scrollAssignmentJS` after every load to restore the saved scroll
  fraction — a real, distinct JS injection a test that only loads HTML once
  and reads it back immediately never exercises.
- **The full recompose+reload cycle.** `SplitEditorView.renderMarkdown()`
  rebuilds the whole HTML document and reloads the WKWebView on every
  `document.text`/`preferences.renderRevision` change — not a live DOM patch.
  A test that loads HTML once and never reloads doesn't exercise this path.

When a bug reproduces in the real app but not in a synthetic test, treat that
gap itself as the next lead — one of the above (or something like it) is
usually the reason, and the Web Inspector is the fastest way to check which.
