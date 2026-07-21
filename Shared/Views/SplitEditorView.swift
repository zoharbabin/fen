import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
    import UIKit
#endif

/// The main split view containing the markdown editor and HTML preview side by side.
public struct SplitEditorView: View {
    @Bindable var document: MarkdownDocument
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
        @Environment(\.openDocument) private var openDocument
    #endif

    public init(document: MarkdownDocument) {
        self.document = document
    }

    @State private var renderer = MarkdownRenderer()
    @State private var composer = HTMLComposer()
    @State private var scrollSync = ScrollSync()
    @State private var outline = DocumentOutline()
    @State private var externalChangeController = ExternalChangeController()
    @State private var autosaveController = AutosaveController()
    @State private var htmlExportController = HTMLExportController()
    #if os(macOS)
        @State private var pdfExportController = PDFExportController()
        @State private var printController = PrintController()
    #endif
    @State private var renderedHTML: String = ""
    @State private var renderTask: Task<Void, Never>?
    @State private var isOutlineVisible = false
    @State private var sourceLineCount = 1
    @State private var sourceLineOffset = 0

    let preferences = Preferences.shared

    enum ViewMode: String, CaseIterable {
        case split = "Split"
        case editorOnly = "Editor"
        case previewOnly = "Preview"
    }

    @State private var viewMode: ViewMode = .split
    @State private var editorOnRight = false
    #if os(macOS)
        @State private var hoveredLinkHref: String?
    #endif
    #if os(iOS)
        @Environment(\.horizontalSizeClass) var horizontalSizeClass
        @State var htmlExportDocument: HTMLExportDocument?
        @State var htmlExportContentType: UTType = .html
        @State var htmlExportFilename = "export.html"
        @State var isHTMLExportPresented = false
        @State var pdfExportDocument: PDFExportDocument?
        @State var pdfExportFilename = "export.pdf"
        @State var isPDFExportPresented = false
        @State var isPDFExporting = false
        @State var printAnchorView: UIView?
        @State var isPrinting = false
    #endif

    public var body: some View {
        // Split into intermediate `let` bindings rather than one long modifier chain -- Swift's
        // expression type-checker solves each statement independently, while a single chained
        // expression covering every `onChange`/`onReceive`/`fileExporter` here (plus their
        // closures) is large enough to exceed its time budget and fail the build outright.
        let base = mainContent
            .toolbar {
                toolbarContent
            }
            .onAppear {
                editorOnRight = preferences.editorOnRight
                preferences.systemPrefersDarkAppearance = colorScheme == .dark
                renderMarkdown()
                externalChangeController.start(for: document)
                autosaveController.start(for: document)
            }
            .onDisappear {
                externalChangeController.stop()
                autosaveController.stop()
            }

        let withChangeHandlers = base
            .onChange(of: document.text) { _, _ in
                scheduleRender()
                autosaveController.textDidChange()
            }
            .onChange(of: preferences.renderRevision) { _, _ in
                renderMarkdown()
            }
            .onChange(of: document.fileURL) { _, _ in
                externalChangeController.start(for: document)
                autosaveController.start(for: document)
            }
            .onChange(of: colorScheme) { _, newValue in
                preferences.systemPrefersDarkAppearance = newValue == .dark
            }

        #if os(macOS)
            let withReceivers = withChangeHandlers
                .onReceive(NotificationCenter.default.publisher(for: DocumentOutline.toggleOutlineNotification)) { _ in
                    isOutlineVisible.toggle()
                }
                .onReceive(NotificationCenter.default.publisher(for: .exportToHTML)) { _ in
                    htmlExportController.presentSavePanel(document: document, preferences: preferences)
                }
                .onReceive(NotificationCenter.default.publisher(for: .exportToPDF)) { _ in
                    pdfExportController.presentSavePanel(document: document, preferences: preferences)
                }
                .onReceive(NotificationCenter.default.publisher(for: .printDocument)) { _ in
                    printController.printDocument(document: document, preferences: preferences)
                }
                .onReceive(NotificationCenter.default.publisher(for: .copyAsRawHTML)) { _ in
                    ClipboardExporter().copyAsRawHTML(
                        markdown: document.text, documentURL: document.fileURL, preferences: preferences
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: .copyAsRichTextFormatted)) { _ in
                    ClipboardExporter().copyAsRichTextFormatted(
                        markdown: document.text, documentURL: document.fileURL, preferences: preferences
                    )
                }
        #else
            let withReceivers = withChangeHandlers
        #endif

        #if os(iOS)
            return withReceivers
                .fileExporter(
                    isPresented: $isHTMLExportPresented,
                    document: htmlExportDocument,
                    contentType: htmlExportContentType,
                    defaultFilename: htmlExportFilename
                ) { _ in }
                .fileExporter(
                    isPresented: $isPDFExportPresented,
                    document: pdfExportDocument,
                    contentType: .pdf,
                    defaultFilename: pdfExportFilename
                ) { _ in }
        #else
            return withReceivers
        #endif
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // On macOS, `HSplitView` gives the outline a real draggable divider (backed by
            // `NSSplitView`) -- a plain `HStack` + static `Divider()` has no drag gesture, which
            // is why the sidebar previously couldn't be resized at all. iOS has no `HSplitView`
            // equivalent, so it keeps the fixed-width `HStack` layout.
            //
            // `centerContent` stays outside the `if isOutlineVisible` branch so it keeps the same
            // position in the view tree whether or not the sidebar is showing -- branching the
            // whole `HSplitView` on `isOutlineVisible` (rather than just the sidebar inside it)
            // changed `centerContent`'s identity on every toggle, forcing SwiftUI to tear down
            // and rebuild the editor/preview (including reloading the `WKWebView`) each time,
            // which is what pushed the outline-open UI test over its time budget.
            #if os(macOS)
                HSplitView {
                    if isOutlineVisible {
                        outlineSidebar
                    }
                    centerContent
                }
            #else
                HStack(spacing: 0) {
                    if isOutlineVisible {
                        outlineSidebar
                        Divider()
                    }
                    centerContent
                }
            #endif
            #if os(macOS)
                linkStatusBar
            #endif
        }
    }

    private var centerContent: some View {
        ZStack {
            switch viewMode {
            case .split:
                splitView
            case .editorOnly:
                editorView
            case .previewOnly:
                previewView
            }
        }
    }

    // MARK: - Outline

    private var outlineSidebar: some View {
        DocumentOutlineSidebar(outline: outline, onSelectHeading: jumpToHeading(_:))
    }

    /// Scrolls both panes to a heading's source line, expressed as the same source-fraction
    /// `ScrollSync` already shares between the editor and preview -- reusing the identical
    /// `(startLine - 1 + lineOffset) / totalLines` formula `scroll-sync.js` uses for its own
    /// `data-sourcepos` anchors, so a jump lands exactly where scroll-sync would place that line.
    private func jumpToHeading(_ heading: Heading) {
        guard let startLine = heading.startLine, sourceLineCount > 0 else { return }
        let fraction = CGFloat(startLine - 1 + sourceLineOffset) / CGFloat(sourceLineCount)
        scrollSync.jumpToSourceFraction(min(1, max(0, fraction)))
    }

    // MARK: - Split View

    @ViewBuilder
    private var splitView: some View {
        #if os(macOS)
            HSplitView {
                if editorOnRight {
                    previewView
                    editorView
                } else {
                    editorView
                    previewView
                }
            }
        #else
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if editorOnRight {
                        previewView
                            .frame(width: geometry.size.width / 2)
                        Divider()
                        editorView
                            .frame(width: geometry.size.width / 2)
                    } else {
                        editorView
                            .frame(width: geometry.size.width / 2)
                        Divider()
                        previewView
                            .frame(width: geometry.size.width / 2)
                    }
                }
            }
        #endif
    }

    // MARK: - Editor

    private var editorView: some View {
        MarkdownTextView(
            text: $document.text,
            font: editorFont,
            highlightThemeName: preferences.editorStyleName,
            lineSpacing: preferences.editorLineSpacing,
            horizontalInset: preferences.editorHorizontalInset,
            verticalInset: preferences.editorVerticalInset,
            isWidthLimited: preferences.editorWidthLimited,
            maximumWidth: preferences.editorMaximumWidth,
            isEditable: true,
            scrollsPastEnd: preferences.editorScrollsPastEnd,
            scrollFraction: scrollSync.editorScrollFraction,
            isScrollSyncEnabled: preferences.editorSyncScrolling,
            documentURL: document.fileURL,
            onScroll: { fraction in
                if preferences.editorSyncScrolling {
                    scrollSync.editorDidScroll(to: fraction)
                }
            },
            onTextChange: {
                scheduleRender()
            }
        )
        .accessibilityIdentifier("EditorTextView")
        .accessibilityValue(scrollFractionLabel(scrollSync.editorScrollFraction))
        #if os(macOS)
            .frame(minWidth: 200)
        #endif
    }

    // MARK: - Preview

    private var previewView: some View {
        #if os(macOS)
            PreviewWebView(
                html: renderedHTML,
                baseURL: document.fileURL,
                fontSize: preferences.fontSize,
                scrollFraction: scrollSync.previewScrollFraction,
                onScrollChange: { fraction in
                    if preferences.editorSyncScrolling {
                        scrollSync.previewDidScroll(to: fraction)
                    }
                },
                onOpenInternalLink: { url in
                    openInternalLink(url)
                },
                onHoverLink: { href in
                    hoveredLinkHref = href
                }
            )
            // WKWebView is a native NSView; macOS only surfaces AXValue for
            // roles like scroll areas or text fields, not the generic "Other"
            // role a wrapped webview gets, so a `.accessibilityValue` here is
            // silently dropped. Use a non-hit-testable overlay and expose the
            // fraction as a label instead, which has no such role restriction.
            .overlay(
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("PreviewWebView")
                    .accessibilityLabel(scrollFractionLabel(scrollSync.previewScrollFraction))
            )
            .frame(minWidth: 200)
        #else
            PreviewWebView(
                html: renderedHTML,
                baseURL: document.fileURL,
                fontSize: preferences.fontSize,
                scrollFraction: scrollSync.previewScrollFraction,
                onScrollChange: { fraction in
                    if preferences.editorSyncScrolling {
                        scrollSync.previewDidScroll(to: fraction)
                    }
                },
                onOpenInternalLink: { url in
                    openInternalLink(url)
                }
            )
            .overlay(
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("PreviewWebView")
                    .accessibilityLabel(scrollFractionLabel(scrollSync.previewScrollFraction))
            )
        #endif
    }

    /// Exposes the current scroll position as an accessibility value so
    /// assistive tech (and UI tests) can read sync state without relying on
    /// pixel geometry.
    private func scrollFractionLabel(_ fraction: CGFloat) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    #if os(macOS)
        /// Shows the URL/path of whatever link the pointer is currently over, mirroring the
        /// hover status line browsers show — cleared (empty, not hidden, so the preview's
        /// layout doesn't jump) once the pointer leaves the link.
        private var linkStatusBar: some View {
            Text(hoveredLinkHref ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.bar)
                .accessibilityIdentifier("LinkStatusBar")
                .accessibilityValue(hoveredLinkHref ?? "")
        }
    #endif

    /// Opens a clicked preview link that points at another local file, in a new window rather
    /// than navigating this document's preview pane. macOS's `DocumentGroup` supports opening
    /// an arbitrary file URL as its own window via `openDocument`; iOS has no equivalent
    /// arbitrary-URL API for a `DocumentGroup`-based app, so the link hands off to the system
    /// document viewer/editor instead, matching how an external link already behaves there.
    private func openInternalLink(_ url: URL) {
        #if os(macOS)
            Task {
                try? await openDocument(at: url)
            }
        #else
            UIApplication.shared.open(url)
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                isOutlineVisible.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .help("Toggle Outline")
            .accessibilityIdentifier("OutlineToggleButton")

            Menu {
                ForEach(FormattingAction.allCases, id: \.self) { action in
                    Button {
                        NotificationCenter.default.post(name: .insertMarkdownFormatting, object: action.identifier)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .accessibilityIdentifier(action.accessibilityIdentifier)
                }
            } label: {
                Image(systemName: "textformat")
            }
            .help("Formatting")
            .accessibilityIdentifier("FormattingMenuButton")

            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Button {
                editorOnRight.toggle()
                preferences.editorOnRight = editorOnRight
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("Swap editor and preview positions")

            if preferences.editorShowWordCount {
                Text(wordCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if os(iOS)
                exportMenu
            #endif
        }
    }

    #if os(iOS)
        /// Broken out of `toolbarContent` into its own computed property -- inlined directly in
        /// that `@ToolbarContentBuilder` body, the added `.background(PrintAnchorView(...))`
        /// modifier below pushed the surrounding expression past what the type-checker can solve
        /// in reasonable time (a known SwiftUI cost of stacking modifiers inside a large
        /// `ViewBuilder` tree), matching the existing `outlineSidebar`/`linkStatusBar` pattern of
        /// extracting subviews to keep each builder body small.
        private var exportMenu: some View {
            Menu {
                ForEach(HTMLExportChoice.allCases, id: \.self) { choice in
                    Button(choice.rawValue) { presentHTMLExporter(choice: choice) }
                }
                Button("Export to PDF") { presentPDFExporter() }
                Button("Print…") { presentPrint() }
                Button("Copy as Raw HTML") { copyAsRawHTML() }
                Button("Copy as Rich Text Formatted") { copyAsRichTextFormatted() }
            } label: {
                if isPDFExporting || isPrinting {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
            }
            .disabled(isPDFExporting || isPrinting)
            .help("Export to HTML, PDF, copy, or print")
            .accessibilityIdentifier("ExportToHTMLButton")
            .background(PrintAnchorView(anchorView: $printAnchorView))
        }
    #endif

    // MARK: - Rendering

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            if !preferences.markdownManualRender {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            renderMarkdown()
        }
    }

    private func renderMarkdown() {
        // Per-document overrides (issue #27) only apply when front-matter detection itself is
        // on -- otherwise the `---...---` block renders as literal content, and a `fen:` key
        // inside it must not silently still drive rendering (rule 3.2).
        let documentOverrides: DocumentPreviewOverrides = preferences.htmlDetectFrontMatter
            ? .parse(frontMatter: renderer.peekFrontMatter(document.text))
            : .none

        var options = MarkdownRenderer.Options.from(preferences: preferences)
        options.sourcePositions = true
        options.renderTOC = documentOverrides.rendersTOC ?? options.renderTOC
        let result = renderer.render(document.text, options: options)
        sourceLineCount = document.text.components(separatedBy: .newlines).count
        sourceLineOffset = result.frontMatterLineCount
        outline.update(headings: result.headings)
        renderedHTML = composer.compose(
            title: result.title,
            body: result.html,
            preferences: preferences,
            sourceLineCount: sourceLineCount,
            sourceLineOffset: sourceLineOffset,
            documentOverrides: documentOverrides
        )
    }

    // MARK: - Computed Properties

    private var wordCountText: String {
        let words = document.text.split { $0.isWhitespace || $0.isNewline }.count
        return "\(words) words"
    }

    private var editorFont: PlatformFont {
        PlatformFont(name: preferences.editorFontName, size: preferences.fontSize)
            ?? PlatformFont.monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular)
    }
}
