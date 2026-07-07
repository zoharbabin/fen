import Foundation

// JS-string builders that both platforms' `PreviewWebView.Coordinator` call through
// `evaluateJavaScript` to talk to `window.__fenScrollSync` (`scroll-sync.js`). Kept separate
// from `PreviewWebView.swift` so that file stays focused on the `NSViewRepresentable`/
// `UIViewRepresentable` and `Coordinator` plumbing, not JS glue.

/// Reads the page's current scroll position back as a source fraction, for saving it before a
/// reload triggered by new HTML — identical on macOS and iOS, so it's hoisted out of both
/// `Coordinator`s rather than duplicated. Returns `null` (not a fabricated fraction) when the
/// page doesn't overflow its viewport, e.g. a zoom-out step that shrinks body's rendered height
/// below the window: `scrollTop / (scrollHeight - clientHeight)` would divide by a clamped `1`
/// there, always reading back ~0 regardless of where the page was actually scrolled to. Both
/// `Coordinator`s already fall back to the last known fraction (`result as? CGFloat ??
/// scrollFraction`) when this returns `null`, so a momentarily non-overflowing page can't
/// permanently zero out the remembered scroll position.
let currentSourceFractionJS = """
(function () {
    var maxScroll = document.documentElement.scrollHeight - document.documentElement.clientHeight;
    if (maxScroll <= 0) {
        return null;
    }
    var renderedFraction = document.documentElement.scrollTop / maxScroll;
    return window.__fenScrollSync
        ? window.__fenScrollSync.sourceFractionForRendered(renderedFraction)
        : renderedFraction;
})();
"""

/// Calls `window.__fenScrollSync`'s `method` with `value`, falling back to `value` unchanged
/// when the page has no anchor table yet (e.g. a document too short to sample).
func scrollSyncCallJS(_ method: String, _ value: CGFloat) -> String {
    "window.__fenScrollSync ? window.__fenScrollSync.\(method)(\(value)) : \(value);"
}

/// Sets `document.documentElement.scrollTop` to `fraction`'s rendered position — the
/// load-time restore used on iOS, where (unlike macOS's `scrollAssignmentJS`) no
/// self-triggered-scroll suppression is needed since iOS reads position from
/// `UIScrollViewDelegate` callbacks guarded by `ExternalScrollGuard`, not a DOM listener.
func scrollToSourceFractionJS(_ fraction: CGFloat) -> String {
    """
    (function () {
        var renderedFraction = \(fraction);
        if (window.__fenScrollSync) {
            renderedFraction = window.__fenScrollSync.renderedFractionForSource(renderedFraction);
        }
        document.documentElement.scrollTop = renderedFraction *
            Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
    })();
    """
}

/// Applies a new font-scale ratio live, without a page reload -- used by a zoom step so the
/// preview updates in place instead of flashing to the top and back during a WKWebView
/// navigation. Reads the current source fraction with the same overflow guard as
/// `currentSourceFractionJS` (skipped, not fabricated, when the page doesn't overflow), writes
/// the two CSS custom properties `HTMLComposer.fontScaleCSS` reads, then re-applies a fraction
/// against the newly-scaled layout -- all in one script call, so there's no intermediate frame
/// to flash between the old and new position. `fallbackFraction` (the Swift side's last known
/// good fraction, i.e. `savedScrollFraction`) stands in for the read whenever the page doesn't
/// currently overflow -- e.g. zooming out again from an already-collapsed state, or zooming
/// back in from one -- so this can't lose the position the same way the pre-fix
/// `currentSourceFractionJS` did. Always returns the fraction actually used (never `null`), so
/// the caller's `savedScrollFraction` stays in sync for a later reload triggered by something
/// else. `suppressScrollEvent` mirrors `scrollAssignmentJS`'s JS-side guard, needed only on
/// macOS where a DOM 'scroll' listener would otherwise report this self-triggered scroll back
/// as if the user had scrolled; iOS relies solely on the Swift-side `ExternalScrollGuard` for that.
func fontScaleAssignmentJS(
    scale: CGFloat,
    inverseScale: CGFloat,
    fallbackFraction: CGFloat,
    suppressScrollEvent: Bool
) -> String {
    let beginSuppress = suppressScrollEvent ? "window.__fenSuppressScrollEvent = true;" : ""
    let endSuppress = suppressScrollEvent
        ? "requestAnimationFrame(function () { requestAnimationFrame(function () { " +
        "window.__fenSuppressScrollEvent = false; }); });"
        : ""
    return """
    (function () {
        var maxScrollBefore = document.documentElement.scrollHeight - document.documentElement.clientHeight;
        var sourceFraction = \(fallbackFraction);
        if (maxScrollBefore > 0) {
            var renderedFractionBefore = document.documentElement.scrollTop / maxScrollBefore;
            sourceFraction = window.__fenScrollSync
                ? window.__fenScrollSync.sourceFractionForRendered(renderedFractionBefore)
                : renderedFractionBefore;
        }
        \(beginSuppress)
        document.documentElement.style.setProperty('--fen-font-scale', '\(scale)');
        document.documentElement.style.setProperty('--fen-font-inverse-scale', '\(inverseScale)');
        var renderedFraction = window.__fenScrollSync
            ? window.__fenScrollSync.renderedFractionForSource(sourceFraction)
            : sourceFraction;
        document.documentElement.scrollTop = renderedFraction *
            Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
        \(endSuppress)
        return sourceFraction;
    })();
    """
}

#if os(macOS)

    /// WKWebView dispatches the DOM 'scroll' event asynchronously (typically on the next
    /// frame) after a programmatic scrollTop assignment, decoupled from
    /// evaluateJavaScript's own completion callback. A Swift-side "is this external"
    /// flag cleared from that callback races the event and can clear too early, letting
    /// a self-triggered scroll leak back through as if the user had scrolled — the drift
    /// compounds every time this happens. window.__fenSuppressScrollEvent is set alongside
    /// every programmatic assignment (see scrollAssignmentJS) and cleared only once the
    /// browser has actually dispatched (or skipped) the resulting scroll event, so this
    /// listener's guard is synchronized with the real event timing instead of a guess.
    let scrollObserverJS = """
    window.addEventListener('scroll', function() {
        if (window.__fenSuppressScrollEvent) { return; }
        var scrollFraction = document.documentElement.scrollTop /
            Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
        if (window.__fenScrollSync) {
            scrollFraction = window.__fenScrollSync.sourceFractionForRendered(scrollFraction);
        }
        window.webkit.messageHandlers.scrollHandler.postMessage(scrollFraction);
    });
    """

    /// Suppresses the DOM 'scroll' event this assignment itself triggers. WKWebView
    /// dispatches that event asynchronously (around the next frame), well after this
    /// script returns and evaluateJavaScript's completion handler runs on the Swift
    /// side — so a Swift-side "ignore the next scroll" flag cleared from that
    /// completion handler always races the real event and can clear before it fires,
    /// letting the self-triggered scroll leak back through scrollObserverJS as if the
    /// user had scrolled. Clearing __fenSuppressScrollEvent after two nested
    /// requestAnimationFrame callbacks (not the completion handler) ties the guard to
    /// the same frame timing the browser uses to actually dispatch the event.
    func scrollAssignmentJS(fraction: CGFloat) -> String {
        """
        (function () {
            var renderedFraction = \(fraction);
            if (window.__fenScrollSync) {
                renderedFraction = window.__fenScrollSync.renderedFractionForSource(renderedFraction);
            }
            window.__fenSuppressScrollEvent = true;
            document.documentElement.scrollTop = renderedFraction *
                Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
            requestAnimationFrame(function () {
                requestAnimationFrame(function () {
                    window.__fenSuppressScrollEvent = false;
                });
            });
        })();
        """
    }

#endif
