import Observation
import SwiftUI
#if os(iOS)
    import UIKit
#endif

/// Finds documents related to what you select, write, or point at in the outline (issue #8), and
/// holds the edit for "Insert Link". It reads the local search index, so it works for files you
/// have not opened. It never changes your text by itself: the edit waits for your click.
@MainActor @Observable
final class RelatedController {
    enum Trigger: Equatable {
        case selection
        case editing
        case heading(String)
    }

    private(set) var suggestions: [RelatedSuggestion] = []
    private(set) var trigger: Trigger?
    /// The edit the editor should apply next. Set only by `insertLink`.
    private(set) var insertion: EditorInsertion?

    // Bookkeeping stays out of Observation: the selection callback fires while SwiftUI updates the
    // editor, and only `suggestions`, `trigger` and `insertion` may change the view.
    @ObservationIgnored private let library: WorkspaceLibrary
    @ObservationIgnored private var context: EditorSelection?
    @ObservationIgnored private var location: (workspace: Workspace, relativePath: String)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var dismissedText: String?
    @ObservationIgnored private var started = false

    init(library: WorkspaceLibrary = .shared) {
        self.library = library
    }

    /// The editor's selection or paragraph changed. `nil` means there is nothing to look up.
    func editorChanged(_ selection: EditorSelection?, fileURL: URL?) {
        if insertion != nil {
            insertion = nil
        }
        guard let selection, let fileURL else {
            clear()
            return
        }
        context = selection
        let isSelection = selection.kind == .selection
        look(
            for: selection.text,
            trigger: isSelection ? .selection : .editing,
            fileURL: fileURL,
            after: isSelection ? .milliseconds(400) : .milliseconds(1200)
        )
    }

    /// You rested the pointer on an outline heading. `section` is the text under it.
    func headingHovered(_ title: String, section: String?, fileURL: URL?) {
        guard let section, let fileURL else { return }
        context = nil
        look(for: section, trigger: .heading(title), fileURL: fileURL, after: .milliseconds(300))
    }

    func cancelPending() {
        task?.cancel()
    }

    func dismiss() {
        dismissedText = context?.text
        clear()
    }

    /// Hands the editor an edit made elsewhere, such as the Properties panel. It lands in the undo
    /// stack like typing.
    func apply(_ edit: EditorInsertion) {
        insertion = edit
    }

    /// Whether "Insert Link" can work for the current suggestions.
    var canInsert: Bool {
        context != nil
    }

    /// Replaces your selection with a link that keeps its words, or adds a link after your paragraph.
    func insertLink(_ suggestion: RelatedSuggestion) {
        guard let context, let from = location?.relativePath else { return }
        switch context.kind {
        case .selection:
            insertion = EditorInsertion(
                range: context.range, expected: context.text,
                text: suggestion.markdownLink(from: from, text: context.text)
            )
        case .paragraph:
            insertion = EditorInsertion(
                range: context.range,
                expected: "",
                text: " " + suggestion.markdownLink(from: from)
            )
        }
        dismiss()
    }

    /// The file for a suggestion, if it is still in its workspace.
    func url(for suggestion: RelatedSuggestion) -> URL? {
        library.fileURL(workspaceID: suggestion.workspaceID, relativePath: suggestion.relativePath)
    }

    private func look(for text: String, trigger: Trigger, fileURL: URL, after delay: Duration) {
        task?.cancel()
        guard text != dismissedText else { return }
        task = Task { [weak self] in
            // A cancelable debounce: it waits out your typing or selecting, not another task.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if !started {
                started = true
                library.start()
            }
            guard let located = library.locate(fileURL) else {
                clear()
                return
            }
            let found = await library.related(to: text, from: located.relativePath, in: located.workspace)
            guard !Task.isCancelled else { return }
            location = located
            suggestions = found
            self.trigger = found.isEmpty ? nil : trigger
        }
    }

    private func clear() {
        task?.cancel()
        context = nil
        if !suggestions.isEmpty {
            suggestions = []
        }
        if trigger != nil {
            trigger = nil
        }
    }
}

/// The card that lists related documents next to the editor. Nothing here changes your text
/// until you press "Insert Link".
struct RelatedSuggestionsCard: View {
    let controller: RelatedController
    #if os(macOS)
        @Environment(\.openDocument) private var openDocument
    #endif

    var body: some View {
        if !controller.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline).lineLimit(1)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { controller.dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.suggestions) { suggestion in
                            row(suggestion)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            .padding(12)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 6)
            .padding(12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("RelatedSuggestions")
        }
    }

    private var title: String {
        if case let .heading(name) = controller.trigger {
            return "Related to “\(name)”"
        }
        return "Related documents"
    }

    private func row(_ suggestion: RelatedSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(suggestion.title.isEmpty ? suggestion.relativePath : suggestion.title).font(.subheadline.bold())
            Text(suggestion.reasonText).font(.caption).foregroundStyle(.secondary)
            if !suggestion.passage.isEmpty {
                Text(suggestion.passage).font(.caption).lineLimit(2)
            }
            HStack {
                Button("Open") { open(suggestion) }
                if controller.canInsert {
                    Button("Insert Link") { controller.insertLink(suggestion) }
                        .help("Adds a link in your text. Undo takes it back.")
                }
            }
            .font(.caption)
        }
        .accessibilityElement(children: .contain)
    }

    private func open(_ suggestion: RelatedSuggestion) {
        guard let url = controller.url(for: suggestion) else { return }
        #if os(macOS)
            Task { try? await openDocument(at: url) }
        #else
            Task { await UIApplication.shared.open(url) }
        #endif
    }
}

extension View {
    /// Shows `controller`'s suggestions in the bottom corner of this view.
    func relatedSuggestions(_ controller: RelatedController) -> some View {
        overlay(alignment: .bottomTrailing) { RelatedSuggestionsCard(controller: controller) }
    }
}

extension SplitEditorView {
    var outlineSidebar: some View {
        VStack(spacing: 0) {
            DocumentOutlineSidebar(
                outline: outline,
                onSelectHeading: jumpToHeading(_:),
                onRestOnHeading: relatedToHeading(_:)
            )
            PropertiesSection(
                text: document.text,
                fileURL: document.fileURL,
                library: .shared,
                change: applyPropertyEdit(_:)
            )
            BacklinksSection(fileURL: document.fileURL, library: .shared, open: openInternalLink(_:))
        }
        .frame(minWidth: 140, idealWidth: 200, maxWidth: 320)
    }

    /// Turns the Properties panel's new text into one small editor edit.
    func applyPropertyEdit(_ newText: String) {
        if let edit = EditorInsertion.minimalEdit(from: document.text, to: newText) {
            related.apply(edit)
        }
    }

    /// Resolves `[[names]]` in the open document, or `nil` when there are none to resolve or the
    /// file is in no workspace.
    func wikiLinkResolver() -> WikiLinkResolver? {
        guard document.text.contains("[[") else { return nil }
        WorkspaceLibrary.shared.start()
        return WorkspaceLibrary.shared.wikiLinkResolver(for: document.fileURL)
    }

    /// Looks up documents related to the section under `heading`.
    func relatedToHeading(_ heading: Heading) {
        related.headingHovered(
            heading.text,
            section: EditorSelection.section(ofHeading: heading.text, level: heading.level, in: document.text),
            fileURL: document.fileURL
        )
    }
}
