import Foundation
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

        guard let fileURL = Self.resolvedFileURL(for: url, baseDirectory: baseDirectory),
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

    /// Resolves `url`'s path against `baseDirectory`, standardizing it and rejecting anything
    /// that escapes `baseDirectory` — the one gate between a clicked/loaded link and the local
    /// filesystem. Shared by `webView(_:start:)` (serving a relative asset) and
    /// `internalLinkTarget(for:baseDirectory:)` (deciding whether a clicked link points at
    /// another file on disk), so both paths enforce the exact same traversal guard.
    ///
    /// Resolves symlinks (`resolvingSymlinksInPath`) on both sides before the prefix check, not
    /// just `standardizedFileURL` (which only collapses `.`/`..` segments): a symlink planted
    /// inside `baseDirectory` but pointing outside it would otherwise pass the prefix check on
    /// its un-resolved path and then read whatever it points at on disk.
    private static func resolvedFileURL(for url: URL, baseDirectory: URL?) -> URL? {
        guard let baseDirectory,
              let candidate = URL(string: String(url.path.dropFirst()), relativeTo: baseDirectory) else {
            return nil
        }
        let fileURL = candidate.resolvingSymlinksInPath()
        let resolvedBase = baseDirectory.resolvingSymlinksInPath()
        guard fileURL.path.hasPrefix(resolvedBase.path) else {
            return nil
        }
        return fileURL
    }

    /// A clicked link that resolves to a *different* file on disk (as opposed to a same-page
    /// anchor like a TOC entry or footnote backref, which keeps the existing `#fragment` on
    /// `fen-preview://local/index.html`) should open in a new Fen window rather than navigate
    /// this preview's `WKWebView` in place — the latter would load that file's raw text as if
    /// it were HTML. Returns `nil` for anchors, external links, and anything that fails the
    /// same traversal guard `webView(_:start:)` applies to asset loads.
    func internalLinkTarget(for url: URL) -> URL? {
        guard !Self.shouldOpenExternally(url), url.path != "/index.html" else { return nil }
        return Self.resolvedFileURL(for: url, baseDirectory: baseDirectory)
    }
}
