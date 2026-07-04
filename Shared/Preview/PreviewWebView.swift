import SwiftUI
import WebKit

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

            webView.loadHTMLString(html, baseURL: baseURL)
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
                (document.documentElement.scrollHeight - document.documentElement.clientHeight)
                """
                webView.evaluateJavaScript(scrollFractionJS) { result, _ in
                    context.coordinator.savedScrollFraction = (result as? CGFloat) ?? scrollFraction
                    webView.loadHTMLString(html, baseURL: baseURL)
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
            private var isApplyingExternalScroll = false
            private var lastAppliedScrollFraction: CGFloat?

            init(_ parent: PreviewWebView) {
                self.parent = parent
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                // Restore scroll position after load
                let fraction = savedScrollFraction
                lastAppliedScrollFraction = fraction
                let js = """
                document.documentElement.scrollTop = \(fraction) *
                    (document.documentElement.scrollHeight - document.documentElement.clientHeight);
                """
                webView.evaluateJavaScript(js)
            }

            @MainActor func applyScrollFraction(_ fraction: CGFloat, to webView: WKWebView) {
                guard lastAppliedScrollFraction == nil || abs(fraction - lastAppliedScrollFraction!) > 0.001
                else { return }
                lastAppliedScrollFraction = fraction
                isApplyingExternalScroll = true
                let js = """
                document.documentElement.scrollTop = \(fraction) *
                    (document.documentElement.scrollHeight - document.documentElement.clientHeight);
                """
                webView.evaluateJavaScript(js) { [weak self] _, _ in
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

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            webView.scrollView.delegate = context.coordinator
            context.coordinator.webView = webView

            webView.loadHTMLString(html, baseURL: baseURL)
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
                    webView.loadHTMLString(html, baseURL: baseURL)
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
            private var isApplyingExternalScroll = false
            private var lastAppliedScrollFraction: CGFloat?

            init(_ parent: PreviewWebView) {
                self.parent = parent
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                let fraction = savedScrollFraction
                lastAppliedScrollFraction = fraction
                let js = """
                document.documentElement.scrollTop = \(fraction) *
                    (document.documentElement.scrollHeight - document.documentElement.clientHeight);
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
