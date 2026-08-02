import Cocoa
import FenCore
import Quartz
import WebKit

/// `QLPreviewingController` glue for `.md` files (issue #49) -- Finder/qlmanage instantiate a
/// fresh instance of this class per preview request, so there is no shared mutable state across
/// requests by construction (rule 1.1). All rendering logic lives in
/// `QuickLookPreviewRenderer`/`DocumentHTMLExporter` (`FenCore`); this class only receives the
/// file URL, calls the shared renderer, and loads the result into a `WKWebView` (rule 5.1).
class PreviewViewController: NSViewController, @MainActor QLPreviewingController {
    override var nibName: NSNib.Name? {
        nil
    }

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    override func loadView() {
        view = NSView()
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// A malformed/binary/oversized file degrades to QuickLook's own built-in "preview
    /// unavailable" UI (via `handler(error)`) rather than a Fen-specific crash (rule 3.1) --
    /// `QuickLookPreviewRenderer.render` never throws for well-formed Markdown of any content,
    /// only for the size cap and unreadable-file cases this maps to `NSError`.
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        Task {
            do {
                let html = try await QuickLookPreviewRenderer().render(fileURL: url)
                webView.loadHTMLString(html, baseURL: nil)
                handler(nil)
            } catch {
                handler(error)
            }
        }
    }
}
