#if os(macOS)
    import AppKit
    import WebKit

    /// Talks to `find.js` in the preview page. The page text goes out to Swift, `FindEngine` matches it, and
    /// the offsets come back to be painted. The query never reaches the page, so there is nothing to escape.
    @MainActor
    final class PreviewFindDriver: FindPreviewTarget {
        /// The name of the message the page posts when its text changed after a search (math or diagrams
        /// finished rendering).
        static let messageName = "findHandler"

        static let script: String = {
            guard let url = coreBundle.url(forResource: "find", withExtension: "js", subdirectory: "Find"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return source
        }()

        /// The script as a user script, for a `WKUserContentController`.
        static func userScript() -> WKUserScript {
            WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        }

        weak var webView: WKWebView?

        init(webView: WKWebView? = nil) {
            self.webView = webView
        }

        var isFindFocused: Bool {
            guard let webView, let responder = webView.window?.firstResponder as? NSView else { return false }
            return responder === webView || responder.isDescendant(of: webView)
        }

        func focusFindTarget() {
            guard let webView else { return }
            webView.window?.makeFirstResponder(webView)
        }

        private func call(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
            guard let webView else { return nil }
            return try? await webView.callAsyncJavaScript(
                "return window.__fenFind ? (\(body)) : null;", arguments: arguments, in: nil, contentWorld: .page
            )
        }

        func findSnapshot(known: Int?) async -> (version: Int, text: String?)? {
            let result = await call("window.__fenFind.snapshot(known)", ["known": known as Any? ?? NSNull()])
            guard let dictionary = result as? [String: Any],
                  let version = dictionary["version"] as? Int else { return nil }
            return (version, dictionary["text"] as? String)
        }

        func findShow(offsets: [Int], version: Int, current: Int?, scroll: Bool) async -> Int? {
            let result = await call(
                "window.__fenFind.show(offsets, version, current, scroll)",
                ["offsets": offsets, "version": version, "current": current ?? -1, "scroll": scroll]
            )
            return result as? Int
        }

        func findSetCurrent(_ index: Int?, scroll: Bool) async {
            _ = await call("window.__fenFind.setCurrent(index, scroll)", ["index": index ?? -1, "scroll": scroll])
        }

        func findClear() async {
            _ = await call("window.__fenFind.clear()")
        }

        func findSelectedText() async -> String? {
            let result = await call("window.getSelection().toString()")
            return (result as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        func findPositions(limit: Int) async -> [Double] {
            let result = await call("window.__fenFind.positions(limit)", ["limit": limit])
            return (result as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        }
    }
#endif
