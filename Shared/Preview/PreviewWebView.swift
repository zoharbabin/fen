import SwiftUI
import WebKit

#if os(macOS)

    /// WKWebView-based preview for macOS.
    struct PreviewWebView: NSViewRepresentable {
        let html: String
        let baseURL: URL?
        var fontSize: CGFloat = Preferences.defaultFontSize
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
            context.coordinator.lastFontSize = fontSize
            return webView
        }

        func updateNSView(_ webView: WKWebView, context: Context) {
            context.coordinator.parent = self
            // Only reload if HTML changed
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                // Save scroll position, reload, restore. A rapid string of renders (e.g.
                // holding Cmd+ to zoom) can start a second one of these round trips before
                // this evaluateJavaScript call returns, so the generation token lets the
                // reload below check it's still the most recently requested one before
                // acting on a possibly-stale read.
                let generation = context.coordinator.beginReload()
                webView.evaluateJavaScript(currentSourceFractionJS) { result, _ in
                    guard context.coordinator.isCurrentReload(generation) else { return }
                    context.coordinator.savedScrollFraction = (result as? CGFloat) ?? scrollFraction
                    context.coordinator.lastFontSize = fontSize
                    context.coordinator.load(html: html, baseURL: baseURL, into: webView)
                }
            } else {
                if context.coordinator.lastFontSize != fontSize {
                    context.coordinator.applyFontSize(fontSize, to: webView)
                }
                context.coordinator.applyScrollFraction(scrollFraction, to: webView)
            }
        }

        class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            var parent: PreviewWebView
            weak var webView: WKWebView?
            var lastHTML: String = ""
            var lastFontSize: CGFloat = Preferences.defaultFontSize
            var savedScrollFraction: CGFloat = 0
            let schemeHandler = PreviewSchemeHandler()
            private let scrollGuard = ExternalScrollGuard()
            private var reloadGeneration = 0

            /// Applies a font-size change live, without a page reload -- see
            /// `fontScaleAssignmentJS`'s doc comment for why this avoids the "jump to top and
            /// back" flash a full reload causes. Guarded like `applyScrollFraction`: unguarded,
            /// the scrollTop write inside the script fires a real DOM scroll event that would
            /// stomp ScrollSync's state.
            @MainActor func applyFontSize(_ fontSize: CGFloat, to webView: WKWebView) {
                lastFontSize = fontSize
                let (scale, inverseScale) = HTMLComposer.fontScaleRatios(fontSize: fontSize)
                let token = scrollGuard.beginExternalScroll()
                webView.evaluateJavaScript(
                    fontScaleAssignmentJS(
                        scale: scale,
                        inverseScale: inverseScale,
                        fallbackFraction: savedScrollFraction,
                        suppressScrollEvent: true
                    )
                ) { [weak self] result, _ in
                    self?.savedScrollFraction = (result as? CGFloat) ?? self?.savedScrollFraction ?? 0
                    self?.scrollGuard.endExternalScroll(token: token)
                }
            }

            /// Call before starting a save-scroll/reload round trip; returns a token that
            /// `isCurrentReload` can check once the async scroll-read comes back, so a
            /// superseded reload (one a newer render request already replaced) never
            /// overwrites `lastHTML`/scroll state with its stale, captured values.
            func beginReload() -> Int {
                reloadGeneration += 1
                return reloadGeneration
            }

            func isCurrentReload(_ generation: Int) -> Bool {
                generation == reloadGeneration
            }

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
        var fontSize: CGFloat = Preferences.defaultFontSize
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
            context.coordinator.lastFontSize = fontSize
            return webView
        }

        func updateUIView(_ webView: WKWebView, context: Context) {
            context.coordinator.parent = self
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                // See the macOS Coordinator's beginReload() doc comment: this guards the
                // same save-scroll/reload race against a rapid string of renders.
                let generation = context.coordinator.beginReload()
                webView.evaluateJavaScript(currentSourceFractionJS) { result, _ in
                    guard context.coordinator.isCurrentReload(generation) else { return }
                    context.coordinator.savedScrollFraction = (result as? CGFloat) ?? scrollFraction
                    context.coordinator.lastFontSize = fontSize
                    context.coordinator.load(html: html, baseURL: baseURL, into: webView)
                }
            } else {
                if context.coordinator.lastFontSize != fontSize {
                    context.coordinator.applyFontSize(fontSize, to: webView)
                }
                context.coordinator.applyScrollFraction(scrollFraction, to: webView.scrollView)
            }
        }

        class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
            var parent: PreviewWebView
            weak var webView: WKWebView?
            var lastHTML: String = ""
            var lastFontSize: CGFloat = Preferences.defaultFontSize
            var savedScrollFraction: CGFloat = 0
            let schemeHandler = PreviewSchemeHandler()
            private let scrollGuard = ExternalScrollGuard()
            private var reloadGeneration = 0

            func beginReload() -> Int {
                reloadGeneration += 1
                return reloadGeneration
            }

            func isCurrentReload(_ generation: Int) -> Bool {
                generation == reloadGeneration
            }

            init(_ parent: PreviewWebView) {
                self.parent = parent
            }

            /// Applies a font-size change live, without a page reload -- see the macOS
            /// Coordinator's `applyFontSize` doc comment. No `__fenSuppressScrollEvent` guard
            /// needed here: iOS reads scroll position from `UIScrollViewDelegate` callbacks
            /// gated by `isApplyingExternalScroll`, not a DOM 'scroll' listener.
            @MainActor func applyFontSize(_ fontSize: CGFloat, to webView: WKWebView) {
                lastFontSize = fontSize
                let (scale, inverseScale) = HTMLComposer.fontScaleRatios(fontSize: fontSize)
                let token = scrollGuard.beginExternalScroll()
                webView.evaluateJavaScript(
                    fontScaleAssignmentJS(
                        scale: scale,
                        inverseScale: inverseScale,
                        fallbackFraction: savedScrollFraction,
                        suppressScrollEvent: false
                    )
                ) { [weak self] result, _ in
                    self?.savedScrollFraction = (result as? CGFloat) ?? self?.savedScrollFraction ?? 0
                    self?.scrollGuard.endExternalScroll(token: token)
                }
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
