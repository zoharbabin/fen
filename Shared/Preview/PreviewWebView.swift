import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Serves the composed preview HTML and resolves relative asset references
/// (images, etc.) against the Markdown document's directory on disk.
///
/// `WKWebView.loadHTMLString(_:baseURL:)` sets the document's base URL for
/// resolving relative links, but does *not* grant the web view read access
/// to that directory, so local images referenced with a relative path never
/// load. Serving through a custom URL scheme sidesteps that restriction
/// without writing any files to disk.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "fen-preview"
    static let previewURL = URL(string: "\(scheme)://local/index.html")!

    var html: String = ""
    var baseDirectory: URL?

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        if url.path == "/index.html" {
            let data = Data(html.utf8)
            let response = URLResponse(
                url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"
            )
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
            return
        }

        guard let baseDirectory,
              let fileURL = URL(string: String(url.path.dropFirst()), relativeTo: baseDirectory)?.standardizedFileURL,
              fileURL.path.hasPrefix(baseDirectory.standardizedFileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}

    /// A clicked link should only hand off to the OS when it targets something outside the
    /// preview document itself — same-page anchors (TOC entries, footnote backrefs) stay on
    /// `fen-preview://`, which has no registered app and would otherwise trigger an
    /// "no application set to open this URL" alert.
    static func shouldOpenExternally(_ url: URL) -> Bool {
        url.scheme != scheme
    }
}

#if os(macOS)

    /// WKWebView-based preview for macOS.
    struct PreviewWebView: NSViewRepresentable {
        let html: String
        let baseURL: URL?
        var scrollFraction: CGFloat
        var onScrollChange: ((CGFloat) -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.preferences.isElementFullscreenEnabled = false
            config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            context.coordinator.webView = webView

            // Allow scrolling observation via JS
            let script = WKUserScript(
                source: scrollObserverJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(script)
            webView.configuration.userContentController.add(
                context.coordinator,
                name: "scrollHandler"
            )

            context.coordinator.load(html: html, baseURL: baseURL, into: webView)
            context.coordinator.lastHTML = html
            return webView
        }

        func updateNSView(_ webView: WKWebView, context: Context) {
            context.coordinator.parent = self
            // Only reload if HTML changed
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                // Save scroll position, reload, restore
                webView.evaluateJavaScript(currentSourceFractionJS) { result, _ in
                    context.coordinator.savedScrollFraction = (result as? CGFloat) ?? scrollFraction
                    context.coordinator.load(html: html, baseURL: baseURL, into: webView)
                }
            } else {
                context.coordinator.applyScrollFraction(scrollFraction, to: webView)
            }
        }

        class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            var parent: PreviewWebView
            weak var webView: WKWebView?
            var lastHTML: String = ""
            var savedScrollFraction: CGFloat = 0
            let schemeHandler = PreviewSchemeHandler()
            private let scrollGuard = ExternalScrollGuard()

            init(_ parent: PreviewWebView) {
                self.parent = parent
            }

            func load(html: String, baseURL: URL?, into webView: WKWebView) {
                scrollGuard.reset()
                schemeHandler.html = html
                schemeHandler.baseDirectory = baseURL?.deletingLastPathComponent()
                webView.load(URLRequest(url: PreviewSchemeHandler.previewURL))
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                if scrollGuard.hasScrolledSinceLoad {
                    // ScrollSync already applied a fraction while this page was still loading
                    // (e.g. slow remote images delayed didFinish past that update). Re-apply it
                    // now that layout has settled instead of overwriting it with the stale
                    // load-time snapshot below, which would visibly snap the page back.
                    scrollGuard.clearLastApplied()
                    applyScrollFraction(parent.scrollFraction, to: webView)
                    return
                }
                // Restore scroll position after load. Guarded like applyScrollFraction:
                // unguarded, this fires a real DOM scroll event that would stomp ScrollSync's state.
                let fraction = savedScrollFraction
                scrollGuard.recordPendingScroll(fraction, countsAsSinceLoad: false)
                let token = scrollGuard.beginExternalScroll()
                webView.evaluateJavaScript(scrollAssignmentJS(fraction: fraction)) { [weak self] _, _ in
                    self?.scrollGuard.endExternalScroll(token: token)
                }
            }

            @MainActor func applyScrollFraction(_ fraction: CGFloat, to webView: WKWebView) {
                guard scrollGuard.shouldApply(fraction) else { return }
                scrollGuard.recordPendingScroll(fraction)
                let token = scrollGuard.beginExternalScroll()
                webView.evaluateJavaScript(scrollAssignmentJS(fraction: fraction)) { [weak self] _, _ in
                    self?.scrollGuard.endExternalScroll(token: token)
                }
            }

            @MainActor
            func webView(
                _: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction,
                preferences: WKWebpagePreferences
            ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
                if navigationAction.navigationType == .linkActivated,
                   let url = navigationAction.request.url,
                   PreviewSchemeHandler.shouldOpenExternally(url) {
                    #if os(macOS)
                        NSWorkspace.shared.open(url)
                    #else
                        await UIApplication.shared.open(url)
                    #endif
                    return (.cancel, preferences)
                } else {
                    return (.allow, preferences)
                }
            }

            func userContentController(
                _: WKUserContentController,
                didReceive message: WKScriptMessage
            ) {
                guard !scrollGuard.isApplyingExternalScroll, let fraction = message.body as? Double else { return }
                scrollGuard.recordIncomingScroll(CGFloat(fraction))
                parent.onScrollChange?(CGFloat(fraction))
            }
        }
    }

#else

    /// WKWebView-based preview for iOS.
    struct PreviewWebView: UIViewRepresentable {
        let html: String
        let baseURL: URL?
        var scrollFraction: CGFloat
        var onScrollChange: ((CGFloat) -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            webView.scrollView.delegate = context.coordinator
            context.coordinator.webView = webView

            context.coordinator.load(html: html, baseURL: baseURL, into: webView)
            context.coordinator.lastHTML = html
            return webView
        }

        func updateUIView(_ webView: WKWebView, context: Context) {
            context.coordinator.parent = self
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                webView.evaluateJavaScript(currentSourceFractionJS) { result, _ in
                    context.coordinator.savedScrollFraction = (result as? CGFloat) ?? scrollFraction
                    context.coordinator.load(html: html, baseURL: baseURL, into: webView)
                }
            } else {
                context.coordinator.applyScrollFraction(scrollFraction, to: webView.scrollView)
            }
        }

        class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
            var parent: PreviewWebView
            weak var webView: WKWebView?
            var lastHTML: String = ""
            var savedScrollFraction: CGFloat = 0
            let schemeHandler = PreviewSchemeHandler()
            private let scrollGuard = ExternalScrollGuard()

            init(_ parent: PreviewWebView) {
                self.parent = parent
            }

            func load(html: String, baseURL: URL?, into webView: WKWebView) {
                scrollGuard.reset()
                schemeHandler.html = html
                schemeHandler.baseDirectory = baseURL?.deletingLastPathComponent()
                webView.load(URLRequest(url: PreviewSchemeHandler.previewURL))
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                if scrollGuard.hasScrolledSinceLoad {
                    // ScrollSync already applied a fraction while this page was still loading
                    // (e.g. slow remote images delayed didFinish past that update). Re-apply it
                    // now that layout has settled instead of overwriting it with the stale
                    // load-time snapshot below, which would visibly snap the page back.
                    scrollGuard.clearLastApplied()
                    applyScrollFraction(parent.scrollFraction, to: webView.scrollView)
                    return
                }
                // Restore scroll position after load. Guarded like applyScrollFraction:
                // unguarded, this fires a real DOM scroll event that would stomp ScrollSync's state.
                let fraction = savedScrollFraction
                scrollGuard.recordPendingScroll(fraction, countsAsSinceLoad: false)
                let token = scrollGuard.beginExternalScroll()
                webView.evaluateJavaScript(scrollToSourceFractionJS(fraction)) { [weak self] _, _ in
                    self?.scrollGuard.endExternalScroll(token: token)
                }
            }

            func webView(
                _: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction,
                decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
            ) {
                if navigationAction.navigationType == .linkActivated,
                   let url = navigationAction.request.url,
                   PreviewSchemeHandler.shouldOpenExternally(url) {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                guard !scrollGuard.isApplyingExternalScroll else { return }
                let contentHeight = scrollView.contentSize.height
                let visibleHeight = scrollView.bounds.height
                guard contentHeight > visibleHeight else { return }
                let renderedFraction = max(0, min(1, scrollView.contentOffset.y / (contentHeight - visibleHeight)))
                scrollGuard.recordIncomingScroll(renderedFraction)
                let js = scrollSyncCallJS("sourceFractionForRendered", renderedFraction)
                webView?.evaluateJavaScript(js) { [weak self] result, _ in
                    self?.parent.onScrollChange?((result as? CGFloat) ?? renderedFraction)
                }
            }

            func applyScrollFraction(_ fraction: CGFloat, to scrollView: UIScrollView) {
                guard scrollGuard.shouldApply(fraction) else { return }
                scrollGuard.recordPendingScroll(fraction)
                let js = scrollSyncCallJS("renderedFractionForSource", fraction)
                webView?.evaluateJavaScript(js) { [weak self] result, _ in
                    self?.scrollToRenderedFraction((result as? CGFloat) ?? fraction, in: scrollView)
                }
            }

            private func scrollToRenderedFraction(_ fraction: CGFloat, in scrollView: UIScrollView) {
                let contentHeight = scrollView.contentSize.height
                let visibleHeight = scrollView.bounds.height
                guard contentHeight > visibleHeight else { return }
                let token = scrollGuard.beginExternalScroll()
                let targetY = fraction * (contentHeight - visibleHeight)
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
                scrollGuard.endExternalScroll(token: token)
            }
        }
    }

#endif
