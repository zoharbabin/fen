import Foundation

/// JS injected once per `WKWebView` via `WKUserScript` (like `scrollObserverJS`) that reports
/// which link the pointer is currently over, so `PreviewWebView.Coordinator` can forward it to a
/// status-bar-style UI. Uses `mouseover`/`mouseout` event delegation on `document` rather than a
/// per-link listener, so it keeps working across every page this `WKWebView` ever loads without
/// re-attaching anything after a reload — `WKUserScript`s here run once per navigation, at
/// document-end, the same as `scrollObserverJS`. Posts the link's raw `href` attribute (not the
/// resolved `fen-preview://` URL) so the status bar shows the path as authored in the Markdown
/// source; posts an empty string on mouseout so the Swift side can tell "stopped hovering" apart
/// from "no message received yet".
let linkHoverObserverJS = """
document.addEventListener('mouseover', function (e) {
    var link = e.target.closest ? e.target.closest('a') : null;
    if (link) {
        window.webkit.messageHandlers.linkHoverHandler.postMessage(link.getAttribute('href') || '');
    }
});
document.addEventListener('mouseout', function (e) {
    var link = e.target.closest ? e.target.closest('a') : null;
    if (link && (!e.relatedTarget || !link.contains(e.relatedTarget))) {
        window.webkit.messageHandlers.linkHoverHandler.postMessage('');
    }
});
"""
