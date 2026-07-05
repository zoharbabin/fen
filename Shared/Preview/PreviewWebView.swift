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
                source: Self.scrollObserverJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(script)
            webView.configuration.userContentController.add(
                context.coordinator,
                name: "scrollHandler"
            )

            context.coordinator.load(html: html, baseURL: baseURL, into: webView)
            return webView
        }

        func updateNSView(_ webView: WKWebView, context: Context) {
            context.coordinator.parent = self
            // Only reload if HTML changed
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                // Save scroll position, reload, restore
                let scrollFractionJS = """
                document.documentElement.scrollTop / \
                Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight)
                """
                webView.evaluateJavaScript(scrollFractionJS) { result, _ in
                    context.coordinator.savedScrollFraction = (result as? CGFloat) ?? scrollFraction
                    context.coordinator.load(html: html, baseURL: baseURL, into: webView)
                }
            } else {
                context.coordinator.applyScrollFraction(scrollFraction, to: webView)
            }
        }

        static let scrollObserverJS = """
        window.addEventListener('scroll', function() {
            var scrollFraction = document.documentElement.scrollTop /
                Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
            window.webkit.messageHandlers.scrollHandler.postMessage(scrollFraction);
        });
        """

        class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            var parent: PreviewWebView
            weak var webView: WKWebView?
            var lastHTML: String = ""
            var savedScrollFraction: CGFloat = 0
            let schemeHandler = PreviewSchemeHandler()
            private var isApplyingExternalScroll = false
            private var lastAppliedScrollFraction: CGFloat?

            init(_ parent: PreviewWebView) {
                self.parent = parent
            }

            func load(html: String, baseURL: URL?, into webView: WKWebView) {
                schemeHandler.html = html
                schemeHandler.baseDirectory = baseURL?.deletingLastPathComponent()
                webView.load(URLRequest(url: PreviewSchemeHandler.previewURL))
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                // Restore scroll position after load
                let fraction = savedScrollFraction
                lastAppliedScrollFraction = fraction
                webView.evaluateJavaScript(Self.scrollAssignmentJS(fraction: fraction))
            }

            private static func scrollAssignmentJS(fraction: CGFloat) -> String {
                """
                document.documentElement.scrollTop = \(fraction) *
                    Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
                """
            }

            @MainActor func applyScrollFraction(_ fraction: CGFloat, to webView: WKWebView) {
                guard lastAppliedScrollFraction == nil || abs(fraction - lastAppliedScrollFraction!) > 0.001
                else { return }
                lastAppliedScrollFraction = fraction
                isApplyingExternalScroll = true
                webView.evaluateJavaScript(Self.scrollAssignmentJS(fraction: fraction)) { [weak self] _, _ in
                    self?.isApplyingExternalScroll = false
                }
            }

            @MainActor
            func webView(
                _: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction,
                preferences: WKWebpagePreferences
            ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
                if navigationAction.navigationType == .linkActivated,
                   let url = navigationAction.request.url {
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
                guard !isApplyingExternalScroll, let fraction = message.body as? Double else { return }
                lastAppliedScrollFraction = CGFloat(fraction)
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
                let scrollFractionJS = """
                document.documentElement.scrollTop / \
                Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight)
                """
                webView.evaluateJavaScript(scrollFractionJS) { result, _ in
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
            private var isApplyingExternalScroll = false
            private var lastAppliedScrollFraction: CGFloat?

            init(_ parent: PreviewWebView) {
                self.parent = parent
            }

            func load(html: String, baseURL: URL?, into webView: WKWebView) {
                schemeHandler.html = html
                schemeHandler.baseDirectory = baseURL?.deletingLastPathComponent()
                webView.load(URLRequest(url: PreviewSchemeHandler.previewURL))
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                let fraction = savedScrollFraction
                lastAppliedScrollFraction = fraction
                let js = """
                document.documentElement.scrollTop = \(fraction) *
                    Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight);
                """
                webView.evaluateJavaScript(js)
            }

            func webView(
                _: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction,
                decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
            ) {
                if navigationAction.navigationType == .linkActivated,
                   let url = navigationAction.request.url {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                guard !isApplyingExternalScroll else { return }
                let contentHeight = scrollView.contentSize.height
                let visibleHeight = scrollView.bounds.height
                guard contentHeight > visibleHeight else { return }
                let fraction = max(0, min(1, scrollView.contentOffset.y / (contentHeight - visibleHeight)))
                lastAppliedScrollFraction = fraction
                parent.onScrollChange?(fraction)
            }

            func applyScrollFraction(_ fraction: CGFloat, to scrollView: UIScrollView) {
                guard lastAppliedScrollFraction == nil || abs(fraction - lastAppliedScrollFraction!) > 0.001
                else { return }
                let contentHeight = scrollView.contentSize.height
                let visibleHeight = scrollView.bounds.height
                guard contentHeight > visibleHeight else { return }
                lastAppliedScrollFraction = fraction
                isApplyingExternalScroll = true
                let targetY = fraction * (contentHeight - visibleHeight)
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
                isApplyingExternalScroll = false
            }
        }
    }

#endif
