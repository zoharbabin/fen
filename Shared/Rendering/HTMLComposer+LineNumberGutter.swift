import Foundation

// MARK: - Line-Number Gutter (issue #21)

extension HTMLComposer {
    /// Whole-document line-number gutter (issue #21) -- distinct from
    /// `Highlight/line-numbers.css`'s per-code-block counters (`preferences.htmlLineNumbers`,
    /// wired through `syntaxHighlightingTags`), which this must not change the behavior
    /// of. `scroll-sync.js` builds and draws the actual `.fen-gutter-line` elements (reusing its
    /// `data-sourcepos` anchor machinery per rule 4.1); this only supplies the CSS box for them
    /// and the `window.__fenShowLineNumbers` flag gating that code, mirroring how
    /// `syntaxHighlightingTags` sets `window.__fenLineNumbers` for the code-block feature.
    func lineNumberGutterTags(
        preferences: Preferences,
        wantsDark: Bool
    ) -> (styles: [String], scripts: [String]) {
        guard preferences.editorShowLineNumbers else { return ([], []) }
        return (
            [inlineStyle(Self.lineNumberGutterCSS(wantsDark: wantsDark))],
            [inlineScript("window.__fenShowLineNumbers = true;")]
        )
    }

    /// Reserves a fixed-width left column for `.fen-gutter-line` (drawn by `scroll-sync.js`)
    /// via `body` padding, matching this feature's whole-document scope -- distinct from
    /// `Highlight/line-numbers.css`'s per-`<pre>` counters, which stay untouched.
    ///
    /// Styled to match `EditorGutterRulerView`/`EditorGutterView_iOS`'s editor-pane gutter
    /// (issue #21 follow-up: "same style as the edit view ruler") -- same font family (the
    /// system UI font, see the tabular-nums paragraph below), same text color
    /// (`-apple-system-secondary-label`, the exact CSS equivalent of `NSColor
    /// .secondaryLabelColor`/`UIColor.secondaryLabel` the editor gutter draws with), and a
    /// ruler-style background rail with a right-edge divider (`-apple-system-control-background`/
    /// `-apple-system-separator`, matching `NSRulerView`'s own appearance-adaptive default fill
    /// and `NSColor.separatorColor`). These `-apple-system-*` keywords resolve dynamically from
    /// whatever `NSAppearance`/`UITraitCollection` the window is actually running under, exactly
    /// like the editor gutter's `NSColor`/`UIColor` semantic colors do -- letting `currentColor`
    /// (the theme's own text color) drive them instead would tie them to `previewAppearanceMode`,
    /// which can be set independently of the OS's real appearance; anchoring to the OS keeps both
    /// gutters in visual lockstep with each other under every combination of the two.
    ///
    /// The editor's `numberFont` is `NSFont.monospacedDigitSystemFont(ofSize: font.pointSize *
    /// 0.85, weight: .regular)` -- the system UI font with tabular (monospaced) digits, not a
    /// true monospace face. `-apple-system, BlinkMacSystemFont` is WebKit's system-font stack;
    /// `font-variant-numeric: tabular-nums` requests the same digit-width guarantee
    /// `monospacedDigitSystemFont` provides, so multi-digit line numbers stay column-aligned
    /// exactly as they do in the editor gutter.
    ///
    /// `zoom: var(--fen-font-inverse-scale)` cancels `fontScaleCSS`'s `body { zoom: ... }` on
    /// this element specifically -- the same technique that CSS already applies to `img`/`svg`,
    /// and for the same reason: `scroll-sync.js`'s `elementTop()` reads each leaf's
    /// `getBoundingClientRect()`, which already reflects `body`'s zoom, then writes that
    /// already-zoomed pixel value as this div's own `top`. Left uncountered, a `.fen-gutter-line`
    /// div -- itself a descendant of the zoomed `body` -- has that same zoom factor applied to
    /// its `top` a second time, so it paints at `top * zoom` instead of `top`, drifting further
    /// from its leaf the further down the page and the further `--fen-font-scale` sits from 1.
    /// The background rail (`.fen-gutter-rail`) is `position: fixed`, not a document-spanning
    /// `body::before` -- deliberately: `.fen-gutter-line`'s own `position: absolute` relies on
    /// `body` having no positioned ancestor (see `elementTop()`'s doc comment in scroll-sync.js;
    /// its `top` is a document-pixel coordinate in the *initial containing block*, which giving
    /// `body` `position: relative` would silently redefine out from under it, breaking every
    /// gutter number's position). `position: fixed` needs no positioned ancestor and, being
    /// pinned to the viewport rather than the document, also needs no zoom-cancellation or
    /// document-height measurement -- it mirrors `EditorGutterRulerView`'s own behavior more
    /// closely besides: that ruler is viewport-pinned chrome that visible content scrolls past,
    /// not a layer that scrolls itself.
    ///
    /// `color-scheme: light`/`dark` is set directly on both gutter elements (not `:root`/`body`,
    /// which nothing else in this stylesheet declares) because every `-apple-system-*` keyword
    /// above resolves against the page's own `color-scheme`, not `WKWebView`'s `NSAppearance` --
    /// `PreviewWebView` never sets `.appearance` on itself, so with no `color-scheme` declared
    /// anywhere these keywords would resolve to their light-polarity default regardless of the
    /// real OS/preference state. `wantsDark` is `resolveWantsDark`'s own result (the same
    /// light/dark polarity the theme CSS file and syntax-highlighting theme already resolve
    /// through), so the gutter's OS-semantic colors track `previewAppearanceMode`/the system
    /// appearance exactly in step with the rest of the composed page.
    ///
    /// `.fen-gutter-rail`'s `width: 3.5em` and `body`'s `padding-left` both need the same
    /// `zoom: var(--fen-font-inverse-scale)` cancellation `.fen-gutter-line` already applies to
    /// itself -- without it, at `--fen-font-scale` < 1 (a font size below the default, down to
    /// `Preferences.minFontSize`) the rail's `em`-relative width shrinks along with the ambient
    /// zoom while `.fen-gutter-line`'s own real-pixel width stays constant (it already cancels
    /// that same zoom), so the rail eventually becomes narrower than the number it contains and
    /// the number overflows past its right edge -- reproduced by
    /// `gutterRailNeverNarrowerThanLineAtSmallFontSize`. `calc(3.5em * var(...))` on `body`'s
    /// padding (rather than a second `zoom` on `body` itself, which would double-cancel the
    /// `fontScaleCSS` zoom already there) keeps the reserved column exactly as wide as the rail
    /// it's reserving space for at every font size.
    private static func lineNumberGutterCSS(wantsDark: Bool) -> String {
        let colorScheme = wantsDark ? "dark" : "light"
        return """
        body { padding-left: calc(3.5em * var(--fen-font-inverse-scale)); }
        .fen-gutter-rail {
            position: fixed; top: 0; left: 0; bottom: 0; width: 3.5em;
            color-scheme: \(colorScheme);
            background: -apple-system-control-background;
            border-right: 1px solid -apple-system-separator;
            pointer-events: none;
            zoom: var(--fen-font-inverse-scale);
        }
        .fen-gutter-line {
            position: absolute; left: 0; width: 3em; text-align: right;
            color-scheme: \(colorScheme);
            font-family: -apple-system, BlinkMacSystemFont, ui-monospace, SFMono-Regular, monospace;
            font-variant-numeric: tabular-nums; font-size: 0.85em;
            color: -apple-system-secondary-label;
            user-select: none; pointer-events: none;
            zoom: var(--fen-font-inverse-scale);
        }
        """
    }
}
