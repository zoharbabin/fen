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
        @State private var htmlExportDocument: HTMLExportDocument?
        @State private var htmlExportContentType: UTType = .html
        @State private var htmlExportFilename = "export.html"
        @State private var isHTMLExportPresented = false
        @State private var pdfExportDocument: PDFExportDocument?
        @State private var pdfExportFilename = "export.pdf"
        @State private var isPDFExportPresented = false
        @State private var isPDFExporting = false
    #endif

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if isOutlineVisible {
                    outlineSidebar
                    Divider()
                }
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
            #if os(macOS)
                linkStatusBar
            #endif
        }
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
        .onReceive(NotificationCenter.default.publisher(for: DocumentOutline.toggleOutlineNotification)) { _ in
            isOutlineVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportToHTML)) { _ in
            htmlExportController.presentSavePanel(document: document, preferences: preferences)
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportToPDF)) { _ in
            pdfExportController.presentSavePanel(document: document, preferences: preferences)
        }
        #endif
        #if os(iOS)
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
        #endif
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
                Menu {
                    ForEach(HTMLExportChoice.allCases, id: \.self) { choice in
                        Button(choice.rawValue) { presentHTMLExporter(choice: choice) }
                    }
                    Button("Export to PDF") { presentPDFExporter() }
                } label: {
                    if isPDFExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                }
                .disabled(isPDFExporting)
                .help("Export to HTML or PDF")
                .accessibilityIdentifier("ExportToHTMLButton")
            #endif
        }
    }

    #if os(iOS)
        /// Renders and resolves the export up front (issue #31) -- `.fileExporter` needs a
        /// fully-prepared `FileDocument` before the user picks a destination, unlike macOS's
        /// `NSSavePanel` which can pass a chosen directory into the write step.
        private func presentHTMLExporter(choice: HTMLExportChoice) {
            let baseName = document.title ?? "Untitled"
            let mode: ExportAssetMode = choice == .selfContained
                ? .selfContained
                : .linkedAssets(exportBaseName: baseName)

            let result = DocumentHTMLExporter().export(
                markdown: document.text, documentURL: document.fileURL, preferences: preferences, mode: mode
            )
            let isDirectory = choice == .linkedAssets
            htmlExportDocument = HTMLExportDocument(result: result, isDirectory: isDirectory)
            htmlExportContentType = isDirectory ? .folder : .html
            htmlExportFilename = isDirectory ? baseName : "\(baseName).html"
            isHTMLExportPresented = true
        }

        /// Renders and resolves the export up front (issue #30), same constraint as
        /// `presentHTMLExporter` -- `.fileExporter` needs a fully-prepared `FileDocument` before
        /// the user picks a destination. Rendering to PDF takes longer than composing HTML, so
        /// this runs off the main actor's synchronous path via `Task`, with `isPDFExporting`
        /// disabling the menu button until it finishes.
        private func presentPDFExporter() {
            let baseName = document.title ?? "Untitled"
            let markdown = document.text
            let fileURL = document.fileURL
            isPDFExporting = true
            Task {
                let html = DocumentPDFExporter().export(
                    markdown: markdown,
                    documentURL: fileURL,
                    preferences: preferences
                )
                do {
                    let data = try await PDFRenderer().renderPDFData(
                        html: html, baseDirectory: fileURL?.deletingLastPathComponent()
                    )
                    pdfExportDocument = PDFExportDocument(data: data)
                    pdfExportFilename = "\(baseName).pdf"
                    isPDFExportPresented = true
                } catch {
                    // No alert-presentation hook exists for iOS in this view yet; failure simply
                    // leaves the export sheet unpresented, matching how a cancelled/failed
                    // `.fileExporter` call already behaves with no document set.
                }
                isPDFExporting = false
            }
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
