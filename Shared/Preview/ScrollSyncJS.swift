import Foundation

// JS-string builders that both platforms' `PreviewWebView.Coordinator` call through
// `evaluateJavaScript` to talk to `window.__fenScrollSync` (`scroll-sync.js`). Kept separate
// from `PreviewWebView.swift` so that file stays focused on the `NSViewRepresentable`/
// `UIViewRepresentable` and `Coordinator` plumbing, not JS glue.

/// Reads the page's current scroll position back as a source fraction, for saving it before a
/// reload triggered by new HTML — identical on macOS and iOS, so it's hoisted out of both
/// `Coordinator`s rather than duplicated.
let currentSourceFractionJS = """
(function () {
    var renderedFraction = document.documentElement.scrollTop /
        Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
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
