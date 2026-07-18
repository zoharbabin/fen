import Foundation
import WebKit
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Renders composed print-ready HTML into a paginated PDF via each platform's native print
/// pipeline (issue #30) -- `WKWebView.createPDF` produces one continuous, un-paginated page and
/// ignores CSS page-break rules, so this drives the same print-layout engine `NSPrintOperation`
/// (macOS) / `UIPrintPageRenderer` (iOS) use instead. Holds no stored state across calls beyond
/// a single in-flight render's own web view and delegate, so two `PDFRenderer` instances
/// rendering different documents concurrently never share or corrupt state (rule 1.1).
@MainActor
public final class PDFRenderer {
    public enum PDFRenderError: LocalizedError {
        case loadTimedOut
        case destinationNotWritable
        case renderFailed

        public var errorDescription: String? {
            switch self {
            case .loadTimedOut:
                "The document took too long to prepare for PDF export."
            case .destinationNotWritable:
                "Could not write the PDF file to the chosen location."
            case .renderFailed:
                "Could not generate the PDF file."
            }
        }
    }

    /// US Letter, matching `HTMLComposer`'s other export paths having no page-size preference.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54 // 0.75in

    #if os(macOS)
        private static let printOperationGate = PrintOperationGate()

        /// Strong per-instance reference to the in-flight print run's delegate -- AppKit's
        /// `runModal` completion callback can arrive on a background thread, by which point
        /// Swift's async-function lifetime analysis may already have released a delegate that
        /// exists only as a local variable. Held here instead, and cleared right after use, so
        /// it never leaks across an instance's calls (rule 1.1).
        private var activeRunDelegate: PDFPrintRunDelegate?
    #endif

    public init() {}

    #if os(macOS)
        /// Renders `html` and writes the resulting paginated PDF directly to `destinationURL`,
        /// via `NSPrintOperation`'s `jobDisposition = .save` -- no print dialog, no printer
        /// selection (rule 2.1: no dynamic code execution or interactive process is involved).
        ///
        /// `WKWebView`'s print implementation needs its operation driven through
        /// `runModal(for:delegate:didRun:contextInfo:)` against a real (if offscreen) window --
        /// plain `NSPrintOperation.run()` hangs indefinitely for a WebKit-backed print view, even
        /// inside a running `NSApplication`, confirmed by a local repro before writing this.
        public func renderPDF(
            html: String,
            baseDirectory: URL?,
            to destinationURL: URL,
            loadTimeout: Duration = .seconds(10)
        ) async throws {
            let destinationDirectory = destinationURL.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: destinationDirectory.path) else {
                throw PDFRenderError.destinationNotWritable
            }

            let webView = try await loadOffscreenWebView(
                html: html, baseDirectory: baseDirectory, loadTimeout: loadTimeout
            )

            let printInfo = NSPrintInfo()
            printInfo.paperSize = Self.pageSize
            printInfo.topMargin = Self.margin
            printInfo.bottomMargin = Self.margin
            printInfo.leftMargin = Self.margin
            printInfo.rightMargin = Self.margin
            printInfo.orientation = .portrait
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destinationURL

            let operation = webView.printOperation(with: printInfo)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false

            let hiddenWindow = NSWindow(
                contentRect: CGRect(origin: .zero, size: Self.pageSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            hiddenWindow.contentView = webView

            // AppKit allows only one modal print session per process at a time -- two
            // concurrent `runModal` calls corrupt each other (observed as a crash in this
            // renderer's own isolation test). This gate serializes access to that single
            // process-wide resource; it holds no per-document state, so it doesn't reintroduce
            // the per-instance leakage rule 1.1 guards against.
            await Self.printOperationGate.acquire()
            let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let runDelegate = PDFPrintRunDelegate(continuation: continuation)
                activeRunDelegate = runDelegate
                operation.runModal(
                    for: hiddenWindow,
                    delegate: runDelegate,
                    didRun: #selector(PDFPrintRunDelegate.printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil
                )
            }
            activeRunDelegate = nil
            await Self.printOperationGate.release()

            guard success else {
                try? FileManager.default.removeItem(at: destinationURL)
                throw PDFRenderError.renderFailed
            }
        }
    #else
        /// Renders `html` into paginated PDF `Data` via `UIPrintPageRenderer` fed by the web
        /// view's own print formatter -- the same print-layout engine iOS's system print sheet
        /// uses, without presenting any UI.
        public func renderPDFData(
            html: String,
            baseDirectory: URL?,
            loadTimeout: Duration = .seconds(10)
        ) async throws -> Data {
            let webView = try await loadOffscreenWebView(
                html: html, baseDirectory: baseDirectory, loadTimeout: loadTimeout
            )

            let pageRenderer = UIPrintPageRenderer()
            pageRenderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)

            let paperRect = CGRect(origin: .zero, size: Self.pageSize)
            let printableRect = paperRect.insetBy(dx: Self.margin, dy: Self.margin)
            pageRenderer.setValue(paperRect, forKey: "paperRect")
            pageRenderer.setValue(printableRect, forKey: "printableRect")

            let renderer = UIGraphicsPDFRenderer(bounds: paperRect)
            return renderer.pdfData { context in
                for pageIndex in 0 ..< pageRenderer.numberOfPages {
                    context.beginPage()
                    pageRenderer.drawPage(at: pageIndex, in: context.pdfContextBounds)
                }
            }
        }
    #endif

    /// Loads `html` into an offscreen `WKWebView` through `PreviewSchemeHandler` (the same local
    /// asset-access pipeline the live preview uses, issue #30 rule 2.2), bounded by
    /// `loadTimeout` so a pathological document that never fires `didFinish` fails the export
    /// rather than hanging it forever (rule 3.2).
    private func loadOffscreenWebView(
        html: String,
        baseDirectory: URL?,
        loadTimeout: Duration
    ) async throws -> WKWebView {
        let schemeHandler = PreviewSchemeHandler()
        schemeHandler.html = html
        schemeHandler.baseDirectory = baseDirectory

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.pageSize), configuration: config
        )
        let delegate = PDFLoadDelegate()
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: PreviewSchemeHandler.previewURL))

        let timeoutTask = Task {
            try? await Task.sleep(for: loadTimeout)
            guard !Task.isCancelled else { return }
            delegate.timeOut()
        }
        defer { timeoutTask.cancel() }

        try await delegate.waitForFinish()
        return webView
    }
}

#if os(macOS)
    /// Serializes access to AppKit's single process-wide modal print session -- shared across
    /// every `PDFRenderer` instance deliberately, since the constraint it enforces belongs to
    /// the process, not to any one renderer (unlike the per-document state rule 1.1 forbids
    /// sharing). A simple FIFO queue of continuations, each released by the next `acquire` call.
    private actor PrintOperationGate {
        private var isBusy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !isBusy {
                isBusy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                isBusy = false
            }
        }
    }
#endif

#if os(macOS)
    /// Resolves a single `NSPrintOperation.runModal` callback into a `CheckedContinuation` --
    /// kept alive only for the duration of one `renderPDF` call, never shared across calls
    /// (rule 1.1). `NSPrintOperation` requires its `didRun` selector be an `@objc` method on an
    /// `NSObject`, so this can't be a plain closure.
    private final class PDFPrintRunDelegate: NSObject {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        @objc func printOperationDidRun(_: NSPrintOperation, success: Bool, contextInfo _: UnsafeMutableRawPointer?) {
            continuation?.resume(returning: success)
            continuation = nil
        }
    }
#endif

/// `WKNavigationDelegate` that resolves a single load-or-timeout race for
/// `PDFRenderer.loadOffscreenWebView` -- kept alive by `webView.navigationDelegate` for the
/// duration of one render call, never shared across calls (rule 1.1).
private final class PDFLoadDelegate: NSObject, WKNavigationDelegate {
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
        resume(with: .failure(PDFRenderer.PDFRenderError.loadTimedOut))
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
