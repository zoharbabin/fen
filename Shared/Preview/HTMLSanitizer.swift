import Foundation
import WebKit

/// Sanitizes raw HTML (from `MarkdownRenderer`'s `CMARK_OPT_UNSAFE` output) through the vendored
/// DOMPurify running inside a hidden `WKWebView` -- the only DOM-capable JS engine available
/// without adding a new HTML-parsing dependency (issue #118). DOMPurify itself calls
/// `document.implementation.createHTMLDocument()` internally, so it can't run in a plain
/// Swift/JSContext; `evaluateJavaScript` is async-only by design (no sync variant, to avoid
/// main-thread deadlock), which is why this type's one public entry point is `async`.
///
/// Each instance lazily creates and owns its own hidden web view, reused across calls -- no
/// module-level mutable state, so two instances (e.g. the live preview's and an export path's)
/// never share or corrupt each other's state (rule 1.1).
@MainActor
public final class HTMLSanitizer {
    enum SanitizeError: Error {
        case resourceMissing
    }

    /// Shared instance for callers that issue one export/render at a time and want to reuse the
    /// same loaded hidden `WKWebView` rather than pay its load cost on every call (mirrors
    /// `Preferences.shared`) -- used by `DocumentHTMLExporter`/`DocumentPDFExporter`, whose own
    /// docs promise a pure function of arguments regardless of which sanitizer instance backs
    /// that call. Tests needing isolation still construct their own `HTMLSanitizer()` directly,
    /// as `SplitEditorView` also does per editor instance.
    public static let shared = HTMLSanitizer()

    private var webView: WKWebView?
    private var loadTask: Task<WKWebView, Error>?

    public init() {}

    /// True once the hidden `WKWebView` has been created -- exposed (internal, not `public`) for
    /// `SanitizerLazyLoadVerifyTest.swift` to prove issue #118 rule 4.1's lazy-load guarantee
    /// (the vendored `purify.min.js` is never loaded until the first `sanitize(_:)` call).
    var hasCreatedWebView: Bool {
        webView != nil
    }

    /// Test-only seam for `SanitizerFailClosedTests.swift` to prove that a failed load doesn't
    /// permanently wedge every later `sanitize(_:)` call -- forcing a *real* WKWebView load or
    /// `evaluateJavaScript` failure isn't reliably reproducible from a test (see `sanitize(_:)`'s
    /// doc comment), so this injects a synthetic failure at the same seam `loadedWebView()`
    /// checks, without weakening anything on the production path.
    func forceNextLoadToFailForTesting() {
        loadTask = Task { throw SanitizeError.resourceMissing }
    }

    /// CommonMark only recognizes raw HTML blocks/inline HTML when they begin with a literal
    /// `<` -- so if `markdown` contains none at all, `CMARK_OPT_UNSAFE` cannot have let any raw
    /// HTML through, and the rendered output is guaranteed byte-for-byte identical to what
    /// sanitizing it would produce. Callers use this to skip the async round-trip through the
    /// hidden `WKWebView` on the common case (most documents contain no raw HTML at all), which
    /// matters most on `SplitEditorView`'s live-preview path -- fewer awaited hops per keystroke.
    public static func mayContainRawHTML(_ markdown: String) -> Bool {
        markdown.contains("<")
    }

    /// Runs `dirtyHTML` through `sanitize-config.js`'s `fenSanitize`, stripping anything outside
    /// the union allowlist (GitHub's raw-HTML tag set plus every tag/attribute Fen's own render
    /// pipeline emits -- see that file's doc comment). Fails closed if the hidden web view fails
    /// to load or the JS call fails: escapes `dirtyHTML` as inert text rather than returning it
    /// unchanged, since returning it as-is would let unsanitized `<script>`/`onerror=` content
    /// reach the WKWebView that renders the result (rule 2.1 -- sanitization must be
    /// unconditional, never skippable by making the sanitizer itself fail).
    public func sanitize(_ dirtyHTML: String) async -> String {
        guard let webView = try? await loadedWebView(),
              let encoded = try? JSONEncoder().encode(dirtyHTML),
              let jsonHTML = String(data: encoded, encoding: .utf8),
              let result = try? await webView.evaluateJavaScript("fenSanitize(\(jsonHTML));") as? String
        else {
            return Self.escapeAsPlainText(dirtyHTML)
        }
        return result
    }

    /// Internal (not `private`) so `SanitizerFailClosedTests.swift` can verify this escaping
    /// directly, since forcing the real hidden-`WKWebView` load or `evaluateJavaScript` call to
    /// fail isn't reliably reproducible from a test.
    nonisolated static func escapeAsPlainText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Returns the reused hidden web view, creating and loading it on first use. Concurrent
    /// callers before the first load completes all await the same in-flight `Task` rather than
    /// each starting their own load. Clears `loadTask` on failure so a transient WebKit load
    /// failure (or the 5s timeout) doesn't permanently wedge every later `sanitize(_:)` call into
    /// re-awaiting the same failed `Task` for the rest of the process's lifetime.
    private func loadedWebView() async throws -> WKWebView {
        if let webView {
            return webView
        }
        let task = loadTask ?? Task { try await Self.makeWebView() }
        loadTask = task
        do {
            let webView = try await task.value
            self.webView = webView
            return webView
        } catch {
            loadTask = nil
            throw error
        }
    }

    private static func makeWebView() async throws -> WKWebView {
        guard let purifyJS = loadExtensionResource(named: "purify.min"),
              let configJS = loadExtensionResource(named: "sanitize-config")
        else {
            throw SanitizeError.resourceMissing
        }

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head><body>
        <script>\(purifyJS)</script>
        <script>\(configJS)</script>
        </body></html>
        """

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let delegate = SanitizerLoadDelegate()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: nil)

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            delegate.timeOut()
        }
        defer { timeoutTask.cancel() }

        try await delegate.waitForFinish()
        return webView
    }

    private static func loadExtensionResource(named name: String) -> String? {
        guard let url = coreBundle.url(forResource: name, withExtension: "js", subdirectory: "Extensions") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// `WKNavigationDelegate` that resolves a single load-or-timeout race for
/// `HTMLSanitizer.makeWebView` -- kept alive only for the duration of that one load (mirrors
/// `PDFRenderer`'s `PDFLoadDelegate`), never shared across instances (rule 1.1).
private final class SanitizerLoadDelegate: NSObject, WKNavigationDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false

    func waitForFinish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func timeOut() {
        resume(with: .failure(HTMLSanitizer.SanitizeError.resourceMissing))
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        resume(with: .success(()))
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        resume(with: .failure(error))
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
