import SwiftUI
#if os(iOS)
    import UIKit
#endif

/// The main split view containing the markdown editor and HTML preview side by side.
public struct SplitEditorView: View {
    @Bindable var document: MarkdownDocument
    #if os(macOS)
        @Environment(\.openDocument) private var openDocument
    #endif

    public init(document: MarkdownDocument) {
        self.document = document
    }

    @State private var renderer = MarkdownRenderer()
    @State private var composer = HTMLComposer()
    @State private var scrollSync = ScrollSync()
    @State private var renderedHTML: String = ""
    @State private var renderTask: Task<Void, Never>?

    let preferences = Preferences.shared

    enum ViewMode: String, CaseIterable {
        case split = "Split"
        case editorOnly = "Editor"
        case previewOnly = "Preview"
    }

    @State private var viewMode: ViewMode = .split
    @State private var editorOnRight = false

    public var body: some View {
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
        .toolbar {
            toolbarContent
        }
        .onAppear {
            editorOnRight = preferences.editorOnRight
            renderMarkdown()
        }
        .onChange(of: document.text) { _, _ in
            scheduleRender()
        }
        .onChange(of: preferences.renderRevision) { _, _ in
            renderMarkdown()
        }
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
            isEditable: true,
            scrollsPastEnd: preferences.editorScrollsPastEnd,
            scrollFraction: scrollSync.editorScrollFraction,
            isScrollSyncEnabled: preferences.editorSyncScrolling,
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
        #if os(macOS)
        .frame(minWidth: 200)
        #endif
    }

    /// Exposes the current scroll position as an accessibility value so
    /// assistive tech (and UI tests) can read sync state without relying on
    /// pixel geometry.
    private func scrollFractionLabel(_ fraction: CGFloat) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

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
        }
    }

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
        var options = MarkdownRenderer.Options.from(preferences: preferences)
        options.sourcePositions = true
        let result = renderer.render(document.text, options: options)
        renderedHTML = composer.compose(
            title: result.title,
            body: result.html,
            preferences: preferences,
            sourceLineCount: document.text.components(separatedBy: .newlines).count,
            sourceLineOffset: result.frontMatterLineCount
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
