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
        // Only reload if HTML changed
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            // Save scroll position, reload, restore
            webView.evaluateJavaScript("document.documentElement.scrollTop / (document.documentElement.scrollHeight - document.documentElement.clientHeight)") { result, _ in
                context.coordinator.savedScrollFraction = (result as? CGFloat) ?? self.scrollFraction
                webView.loadHTMLString(html, baseURL: self.baseURL)
            }
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

        init(_ parent: PreviewWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Restore scroll position after load
            let fraction = savedScrollFraction
            let js = """
            document.documentElement.scrollTop = \(fraction) *
                (document.documentElement.scrollHeight - document.documentElement.clientHeight);
            """
            webView.evaluateJavaScript(js)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if let fraction = message.body as? Double {
                parent.onScrollChange?(CGFloat(fraction))
            }
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
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.evaluateJavaScript("document.documentElement.scrollTop / Math.max(1, document.documentElement.scrollHeight - document.documentElement.clientHeight)") { result, _ in
                context.coordinator.savedScrollFraction = (result as? CGFloat) ?? self.scrollFraction
                webView.loadHTMLString(html, baseURL: self.baseURL)
            }
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: PreviewWebView
        weak var webView: WKWebView?
        var lastHTML: String = ""
        var savedScrollFraction: CGFloat = 0

        init(_ parent: PreviewWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let fraction = savedScrollFraction
            let js = """
            document.documentElement.scrollTop = \(fraction) *
                (document.documentElement.scrollHeight - document.documentElement.clientHeight);
            """
            webView.evaluateJavaScript(js)
        }

        func webView(
            _ webView: WKWebView,
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
            let contentHeight = scrollView.contentSize.height
            let visibleHeight = scrollView.bounds.height
            guard contentHeight > visibleHeight else { return }
            let fraction = scrollView.contentOffset.y / (contentHeight - visibleHeight)
            parent.onScrollChange?(max(0, min(1, fraction)))
        }
    }
}

#endif
