import Foundation
import WebKit
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

public extension Notification.Name {
    /// Posted by macOS's "Print…" menu command (`macOS/PrintCommands.swift`) to ask the focused
    /// `SplitEditorView` to present the system print panel -- mirrors `.exportToPDF` (issue #32).
    static let printDocument = Notification.Name("printDocument")
}

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

            let success = await runModalPrintOperation(operation, webView: webView)

            guard success else {
                try? FileManager.default.removeItem(at: destinationURL)
                throw PDFRenderError.renderFailed
            }
        }

        /// Presents the system print panel for `html` -- issue #32's macOS half. Builds the same
        /// offscreen `WKWebView` + `NSPrintInfo` as `renderPDF`, but shows the print panel and
        /// progress panel instead of writing straight to a file, so the user picks a printer (or
        /// "Save as PDF…") from the panel itself; that write path is the OS's own, not this
        /// method's, so no `jobSavingURL`/`jobDisposition` is set here.
        public func printDocument(
            html: String,
            baseDirectory: URL?,
            loadTimeout: Duration = .seconds(10)
        ) async throws {
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

            let operation = webView.printOperation(with: printInfo)
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true

            guard await runModalPrintOperation(operation, webView: webView) else {
                throw PDFRenderError.renderFailed
            }
        }

        /// Runs `operation` against a hidden window hosting `webView`, serialized by the
        /// process-wide `PrintOperationGate` -- the shared "load offscreen webview, build an
        /// `NSPrintOperation`, run it via the gate" logic both `renderPDF` (panel hidden) and
        /// `printDocument` (panel shown) call, rather than each duplicating it (issue #32 rule
        /// 5.1). `WKWebView`'s print implementation needs its operation driven through
        /// `runModal(for:delegate:didRun:contextInfo:)` against a real (if offscreen) window --
        /// plain `NSPrintOperation.run()` hangs indefinitely for a WebKit-backed print view, even
        /// inside a running `NSApplication`, confirmed by a local repro before writing this.
        ///
        /// Not `private`: `PrintIsolationTests`/`PrintControllerTests` (issue #32 rules 1.1/3.1)
        /// drive this directly with `showsPrintPanel = false` and `jobDisposition = .cancel`, the
        /// same mechanism AppKit itself uses to skip UI -- a real `showsPrintPanel = true` run
        /// would pop an actual, unattended dialog and hang a headless test forever.
        func runModalPrintOperation(_ operation: NSPrintOperation, webView: WKWebView) async -> Bool {
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
            return success
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

        /// Builds a `UIPrintInteractionController` ready to present for `html` -- issue #32's iOS
        /// half. Unlike `renderPDFData`'s manual `UIPrintPageRenderer`/`UIGraphicsPDFRenderer`
        /// pagination, `UIPrintInteractionController` paginates live from the web view's own print
        /// formatter, so this needs no page-rendering loop. Presenting the returned controller
        /// (`present(animated:completionHandler:)` on iPhone, `present(from:in:animated:completionHandler:)`
        /// anchored to a rect on iPad) is the caller's responsibility, since that's a UI concern
        /// this renderer has no view hierarchy to participate in.
        public func makePrintInteractionController(
            html: String,
            baseDirectory: URL?,
            documentName: String,
            loadTimeout: Duration = .seconds(10)
        ) async throws -> UIPrintInteractionController {
            let webView = try await loadOffscreenWebView(
                html: html, baseDirectory: baseDirectory, loadTimeout: loadTimeout
            )

            let printInfo = UIPrintInfo(dictionary: nil)
            printInfo.outputType = .general
            printInfo.jobName = documentName

            let controller = UIPrintInteractionController()
            controller.printInfo = printInfo
            controller.printFormatter = webView.viewPrintFormatter()
            return controller
        }
    #endif

    /// Loads `html` into an offscreen `WKWebView` through `PreviewSchemeHandler` (the same local
    /// asset-access pipeline the live preview uses, issue #30 rule 2.2), bounded by
    /// `loadTimeout` so a pathological document that never fires `didFinish` fails the export
    /// rather than hanging it forever (rule 3.2).
    ///
    /// Not `private`: `PrintIsolationTests`/`PrintControllerTests` (issue #32) build their own
    /// offscreen web view through this to drive `runModalPrintOperation` directly.
    func loadOffscreenWebView(
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
