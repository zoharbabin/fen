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
