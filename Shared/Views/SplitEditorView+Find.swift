import SwiftUI

#if os(macOS)

    /// Routes the Find menu commands to this window's `FindState`.
    struct FindCommandReceivers: ViewModifier {
        let find: FindState
        /// The panes on screen are the panes Find searches.
        let panes: Set<FindState.Pane>

        func body(content: Content) -> some View {
            content
                .onChange(of: panes, initial: true) { _, new in find.visiblePanes = new }
                .onWindowCommand(.findShow) { find.present() }
                .onWindowCommand(.findShowReplace) { find.present(replace: true) }
                .onWindowCommand(.findNext) { find.next() }
                .onWindowCommand(.findPrevious) { find.previous() }
                .onWindowCommand(.findUseSelection) { find.useSelection() }
        }
    }

    /// Find (issue #255): which panes the bar searches, and the "other notes match" link.
    extension SplitEditorView {
        /// Restarts the other-notes count when the query text or its mode changes.
        struct OtherNotesKey: Equatable {
            var text: String
            var isRegex: Bool
        }

        @ViewBuilder
        var findBar: some View {
            if find.isPresented {
                FindBar(find: find, otherNotes: otherNotes, searchOtherNotes: searchOtherNotes)
                    .task(id: OtherNotesKey(text: find.query.text, isRegex: find.query.isRegex)) {
                        await refreshOtherNotes()
                    }
            }
        }

        var findPanes: Set<FindState.Pane> {
            switch viewMode.shown(compactWidth: isCompactWidth) {
            case .split: [.editor, .preview]
            case .editorOnly: [.editor]
            case .previewOnly: [.preview]
            }
        }

        /// How many other notes contain the query as words. Meaning-only hits are left out: the bar
        /// promises a match, not a guess. Runs after a short pause, and a new keystroke cancels it.
        func refreshOtherNotes() async {
            otherNotes = nil
            let text = find.query.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let library = WorkspaceLibrary.shared
            guard text.count >= 3, !find.query.isRegex, !library.workspaces.isEmpty else { return }
            // A typing pause, not a synchronization: the task is canceled by the next keystroke.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let here = document.fileURL.flatMap { library.locate($0) }
            let results = await library.search(text, scope: .all, destination: .shownToUser, limit: 50)
            guard !Task.isCancelled else { return }
            let others = results.filter { result in
                result.match != .meaning
                    && !(result.workspaceID == here?.workspace.id && result.relativePath == here?.relativePath)
            }
            otherNotes = OtherNotesMatches(count: others.count)
        }

        func searchOtherNotes(_ text: String) {
            WorkspaceSearchRequest.shared.query = text
            openWindow(id: "workspaces")
        }
    }
#else
    extension SplitEditorView {
        var findBar: some View {
            EmptyView()
        }
    }
#endif
