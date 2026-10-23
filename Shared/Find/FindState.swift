#if os(macOS)
    import AppKit
    import Observation

    /// The editor pane, as Find sees it. `MarkdownTextView.Coordinator` implements it.
    @MainActor
    protocol FindEditorTarget: AnyObject {
        var findText: String { get }
        var findSelection: NSRange { get }
        var isFindFocused: Bool { get }
        /// Highlights every match near the viewport and marks `current`. Never moves the caret or the
        /// selection, because in Live Preview that would turn a rendered line back into source.
        func showFindMatches(_ ranges: [NSRange], current: Int?, scroll: Bool)
        func clearFindMatches()
        /// One undo step for the whole batch. `ranges` are ascending and don't overlap.
        func replaceFindMatches(_ ranges: [NSRange], with strings: [String])
        /// Puts the caret on `range` and focuses the editor.
        func selectFindRange(_ range: NSRange)
        func selectFindRanges(_ ranges: [NSRange])
        func focusFindTarget()
    }

    /// The preview pane, as Find sees it. `PreviewWebView.Coordinator` implements it.
    @MainActor
    protocol FindPreviewTarget: AnyObject {
        var isFindFocused: Bool { get }
        /// The page text. `text` is nil when the page still has the `known` version.
        func findSnapshot(known: Int?) async -> (version: Int, text: String?)?
        /// Returns the page's newer version when it changed since the search ran.
        func findShow(offsets: [Int], version: Int, current: Int?, scroll: Bool) async -> Int?
        func findSetCurrent(_ index: Int?, scroll: Bool) async
        func findClear() async
        func findPositions(limit: Int) async -> [Double]
        func findSelectedText() async -> String?
        func focusFindTarget()
    }

    /// Find for one document window: the query, the options and the results in both panes. The bar
    /// (`FindBar`) edits it. The panes register as targets and are painted from here.
    @MainActor
    @Observable
    final class FindState {
        enum Pane: String, CaseIterable {
            case editor = "Editor"
            case preview = "Preview"
        }

        // MARK: Input

        var isPresented = false
        var showsReplace = false
        var query = FindQuery()
        var replacement = ""
        var keepCase = false
        var inSelection = false
        /// Bumped to put the cursor in the find field, even when the bar is already open.
        private(set) var focusRequest = 0
        /// The pane Next and Previous drive.
        var activePane: Pane = .editor

        // MARK: Output

        private(set) var editorCount = 0
        private(set) var editorCurrent: Int?
        private(set) var previewCount = 0
        private(set) var previewCurrent: Int?
        private(set) var isTruncated = false
        private(set) var isSearching = false
        private(set) var hasInvalidPattern = false
        /// Where the matches sit, as fractions of the pane's height, for the scrollbar strip.
        private(set) var editorStrip: [Double] = []
        private(set) var previewStrip: [Double] = []
        /// What a replace would put at the current match, for the live preview in the bar.
        private(set) var replacementPreview: String?
        /// The nearest word in the note when nothing matches ("Did you mean").
        private(set) var suggestion: String?

        // MARK: Wiring

        /// The panes on screen. `SplitEditorView` keeps it in step with the view mode.
        var visiblePanes: Set<Pane> = [.editor, .preview] {
            didSet {
                if oldValue != visiblePanes {
                    paneSetChanged()
                }
            }
        }

        @ObservationIgnored weak var editor: FindEditorTarget?
        @ObservationIgnored weak var preview: FindPreviewTarget?

        @ObservationIgnored private var editorRanges: [NSRange] = []
        @ObservationIgnored private var previewOffsets: [Int] = []
        @ObservationIgnored private var previewText = ""
        @ObservationIgnored private var previewVersion: Int?
        @ObservationIgnored private var editorAnchor = 0
        @ObservationIgnored private var previewAnchor = 0
        @ObservationIgnored private var selectionScope: NSRange?
        @ObservationIgnored private var searchTask: Task<Void, Never>?
        @ObservationIgnored private var generation = 0

        /// Documents longer than this wait a moment after a keystroke, so typing stays smooth.
        static let largeDocument = 200_000
        static let debounce: Duration = .milliseconds(120)

        // MARK: Derived

        var count: Int {
            activePane == .editor ? editorCount : previewCount
        }

        var current: Int? {
            activePane == .editor ? editorCurrent : previewCurrent
        }

        var canReplace: Bool {
            visiblePanes.contains(.editor)
        }

        /// "3 of 12", "12 matches", "No results". The bar speaks this label too.
        var summary: String {
            if query.isEmpty {
                return ""
            }
            if hasInvalidPattern {
                return "Invalid pattern"
            }
            let total = isTruncated ? "\(FindEngine.maxMatches)+" : "\(count)"
            if count < 1 {
                return isSearching ? "" : "No results"
            }
            if let current {
                return "\(current + 1) of \(total)"
            }
            return count == 1 ? "1 match" : "\(total) matches"
        }

        // MARK: Open and close

        /// Opens the bar, prefilled with the selection (Cmd+F). With the bar open, it selects the field's text.
        func present(replace: Bool = false) {
            syncActivePaneToFocus()
            if !isPresented {
                // The first match is the one at or after the caret, so Find starts where you are.
                editorAnchor = editor?.findSelection.location ?? 0
                previewAnchor = 0
            }
            isPresented = true
            if replace, canReplace {
                showsReplace = true
            }
            focusRequest += 1
            Task {
                if let selection = await selectedText() {
                    query.text = selection
                }
                search(reveal: true)
            }
        }

        /// Cmd+E: the selection becomes the query without opening the bar.
        func useSelection() {
            Task {
                guard let selection = await selectedText() else { return }
                query.text = selection
                if isPresented {
                    search(reveal: true)
                }
            }
        }

        /// Esc. The caret lands on the current match, so you carry on editing from there.
        func dismiss() {
            guard isPresented else { return }
            let target = activePane
            let match = editorCurrent.flatMap { editorRanges.indices.contains($0) ? editorRanges[$0] : nil }
            isPresented = false
            searchTask?.cancel()
            generation += 1
            clearResults()
            editor?.clearFindMatches()
            Task { await preview?.findClear() }
            if target == .editor || !visiblePanes.contains(.preview) {
                if let match {
                    editor?.selectFindRange(match)
                } else {
                    editor?.focusFindTarget()
                }
            } else {
                preview?.focusFindTarget()
            }
        }

        /// The one-line selection in the active pane, if there is one.
        private func selectedText() async -> String? {
            let text: String?
            if activePane == .editor, let editor {
                let selection = editor.findSelection
                let all = editor.findText as NSString
                text = selection.length > 0 && NSMaxRange(selection) <= all.length ? all
                    .substring(with: selection) : nil
            } else {
                text = await preview?.findSelectedText()
            }
            guard let text, text.count <= 200, !text.contains("\n") else { return nil }
            return text
        }

        /// Picks the pane the user is in, from where the keyboard focus is.
        func syncActivePaneToFocus() {
            if visiblePanes.count == 1, let only = visiblePanes.first {
                activePane = only
            } else if editor?.isFindFocused == true {
                activePane = .editor
            } else if preview?.isFindFocused == true {
                activePane = .preview
            }
        }

        private func paneSetChanged() {
            if visiblePanes.count == 1, let only = visiblePanes.first {
                activePane = only
            }
            if !visiblePanes.contains(activePane), let first = visiblePanes.first {
                activePane = first
            }
            if isPresented {
                search(reveal: false)
            }
        }

        // MARK: Search

        func queryChanged() {
            if inSelection, selectionScope == nil {
                lockSelectionScope()
            }
            search(reveal: true)
        }

        /// The editor text changed (typing, replace, undo). Keeps the position and refreshes the matches.
        func documentChanged() {
            guard isPresented else { return }
            if let editor {
                editorAnchor = editor.findSelection.location
            }
            search(reveal: false)
        }

        /// The preview page was reloaded, which wipes its highlights.
        func previewReloaded() {
            guard isPresented else { return }
            previewVersion = nil
            search(reveal: false)
        }

        /// Math or a diagram finished rendering, so the page text moved under the offsets.
        func previewChanged() {
            previewReloaded()
        }

        func inSelectionChanged() {
            if inSelection {
                lockSelectionScope()
            } else {
                selectionScope = nil
            }
            search(reveal: true)
        }

        private func lockSelectionScope() {
            guard let selection = editor?.findSelection, selection.length > 0 else {
                inSelection = false
                return
            }
            selectionScope = selection
        }

        private func clearResults() {
            editorRanges = []
            previewOffsets = []
            editorCount = 0
            previewCount = 0
            editorCurrent = nil
            previewCurrent = nil
            isTruncated = false
            isSearching = false
            hasInvalidPattern = false
            editorStrip = []
            previewStrip = []
            replacementPreview = nil
            suggestion = nil
        }

        func search(reveal: Bool) {
            searchTask?.cancel()
            generation += 1
            let ticket = generation
            guard isPresented, !query.isEmpty else {
                clearResults()
                editor?.clearFindMatches()
                Task { await preview?.findClear() }
                return
            }
            isSearching = true
            let snapshot = query
            let delay: Duration? = (editor?.findText.utf16.count ?? 0) > Self.largeDocument ? Self.debounce : nil
            searchTask = Task { [weak self] in
                if let delay {
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled {
                        return
                    }
                }
                await self?.run(snapshot, reveal: reveal, ticket: ticket)
            }
        }

        private func isCurrent(_ ticket: Int) -> Bool {
            ticket == generation && !Task.isCancelled
        }

        private func run(_ query: FindQuery, reveal: Bool, ticket: Int) async {
            var invalid = false
            var truncated = false
            if visiblePanes.contains(.editor), let editor {
                let text = editor.findText
                let scope = inSelection ? selectionScope : nil
                switch await Self.match(query, in: text, within: scope) {
                case let .success(result):
                    guard isCurrent(ticket) else { return }
                    editorRanges = result.ranges
                    truncated = truncated || result.isTruncated
                    editorCount = result.ranges.count
                    editorCurrent = Self.index(atOrAfter: editorAnchor, in: result.ranges.map(\.location))
                    editor.showFindMatches(
                        result.ranges,
                        current: editorCurrent,
                        scroll: reveal && activePane == .editor
                    )
                case .failure:
                    guard isCurrent(ticket) else { return }
                    invalid = true
                    editorRanges = []
                    editorCount = 0
                    editorCurrent = nil
                    editor.clearFindMatches()
                }
            } else {
                editorRanges = []
                editorCount = 0
                editorCurrent = nil
            }
            if visiblePanes.contains(.preview), let preview, !invalid {
                await runPreview(query, preview: preview, reveal: reveal, ticket: ticket, truncated: &truncated)
            } else {
                previewOffsets = []
                previewCount = 0
                previewCurrent = nil
            }
            guard isCurrent(ticket) else { return }
            isTruncated = truncated
            hasInvalidPattern = invalid
            isSearching = false
            updateReplacementPreview()
            updateSuggestion(for: query, ticket: ticket)
            updateStrip()
            if !(editorCount == 0 && previewCount == 0) {
                suggestion = nil
            }
        }

        private func runPreview(
            _ query: FindQuery, preview: FindPreviewTarget, reveal: Bool, ticket: Int, truncated: inout Bool
        ) async {
            for _ in 0 ..< 2 {
                guard let snapshot = await preview.findSnapshot(known: previewVersion),
                      isCurrent(ticket) else { return }
                if let text = snapshot.text {
                    previewText = text
                }
                previewVersion = snapshot.version
                guard case let .success(result) = await Self.match(query, in: previewText, within: nil),
                      isCurrent(ticket) else {
                    previewOffsets = []
                    previewCount = 0
                    previewCurrent = nil
                    await preview.findClear()
                    return
                }
                truncated = truncated || result.isTruncated
                previewOffsets = result.ranges.flatMap { [$0.location, NSMaxRange($0)] }
                previewCount = result.ranges.count
                previewCurrent = Self.index(atOrAfter: previewAnchor, in: result.ranges.map(\.location))
                let newer = await preview.findShow(
                    offsets: previewOffsets, version: snapshot.version, current: previewCurrent,
                    scroll: reveal && activePane == .preview
                )
                guard newer != nil else { return }
                previewVersion = nil
            }
        }

        /// Runs the engine on a background task that stops when this search is superseded.
        private nonisolated static func match(
            _ query: FindQuery, in text: String, within scope: NSRange?
        ) async -> Result<FindResult, FindError> {
            let work = Task.detached(priority: .userInitiated) { () -> Result<FindResult, FindError> in
                do {
                    return try .success(FindEngine.find(query, in: text, within: scope) { Task.isCancelled })
                } catch {
                    return .failure(.invalidPattern)
                }
            }
            return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        }

        /// The first match that starts at or after `anchor`, wrapping to the first one.
        static func index(atOrAfter anchor: Int, in starts: [Int]) -> Int? {
            guard !starts.isEmpty else { return nil }
            var low = 0
            var high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] < anchor {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low < starts.count ? low : 0
        }

        // MARK: Navigate

        func next() {
            step(1)
        }

        func previous() {
            step(-1)
        }

        private func step(_ direction: Int) {
            guard isPresented, count >= 1 else { return }
            let from = current ?? (direction > 0 ? -1 : 0)
            let target = (from + direction + count) % count
            select(target)
        }

        /// Moves the current match in the active pane. Scrolls only when it is off screen.
        func select(_ index: Int) {
            switch activePane {
            case .editor:
                guard editorRanges.indices.contains(index) else { return }
                editorCurrent = index
                editorAnchor = editorRanges[index].location
                editor?.showFindMatches(editorRanges, current: index, scroll: true)
            case .preview:
                guard index >= 0, index < previewCount else { return }
                previewCurrent = index
                previewAnchor = previewOffsets[index * 2]
                Task { await preview?.findSetCurrent(index, scroll: true) }
            }
            updateReplacementPreview()
        }

        func switchPane(to pane: Pane) {
            guard visiblePanes.contains(pane) else { return }
            activePane = pane
            if let other = Pane.allCases.first(where: { $0 != pane }) {
                // Only the pane you drive has a current match. The other keeps its highlights.
                switch other {
                case .editor: editorCurrent = nil
                case .preview: previewCurrent = nil
                }
            }
            select(current ?? 0)
        }

        // MARK: Replace

        private var currentRange: NSRange? {
            guard activePane == .editor, let editorCurrent, editorRanges.indices.contains(editorCurrent) else {
                return nil
            }
            return editorRanges[editorCurrent]
        }

        private func updateReplacementPreview() {
            guard showsReplace, let range = currentRange, let editor,
                  let strings = try? FindEngine.replacements(
                      for: [range], in: editor.findText, query: query, template: replacement, keepCase: keepCase
                  ) else {
                replacementPreview = nil
                return
            }
            replacementPreview = strings.first
        }

        func replacementChanged() {
            updateReplacementPreview()
        }

        /// The matches in the editor's text right now. A search may still be running, or the text may have
        /// changed under it, so a replace never trusts `editorRanges`.
        private func liveEditorRanges(in text: String) -> [NSRange] {
            let scope = inSelection ? selectionScope : nil
            return (try? FindEngine.find(query, in: text, within: scope).ranges) ?? []
        }

        private func shiftSelectionScope(by delta: Int) {
            guard inSelection, let scope = selectionScope else { return }
            selectionScope = NSRange(location: scope.location, length: max(0, scope.length + delta))
        }

        func replaceCurrent() {
            guard canReplace, let range = currentRange, let editor else { return }
            let text = editor.findText
            guard liveEditorRanges(in: text).contains(range),
                  let strings = try? FindEngine.replacements(
                      for: [range], in: text, query: query, template: replacement, keepCase: keepCase,
                      within: inSelection ? selectionScope : nil
                  ) else { return }
            shiftSelectionScope(by: strings[0].utf16.count - range.length)
            editor.replaceFindMatches([range], with: strings)
        }

        func replaceAll() {
            guard canReplace, let editor else { return }
            let text = editor.findText
            let ranges = liveEditorRanges(in: text)
            guard !ranges.isEmpty,
                  let strings = try? FindEngine.replacements(
                      for: ranges, in: text, query: query, template: replacement, keepCase: keepCase,
                      within: inSelection ? selectionScope : nil
                  ) else { return }
            shiftSelectionScope(by: zip(ranges, strings).reduce(0) { $0 + $1.1.utf16.count - $1.0.length })
            editor.replaceFindMatches(ranges, with: strings)
        }

        /// Selects every match so one edit changes them all (Cmd+Option+Return in the bar).
        func selectAllMatches() {
            guard canReplace, !editorRanges.isEmpty else { return }
            editor?.selectFindRanges(editorRanges)
            dismissKeepingSelection()
        }

        private func dismissKeepingSelection() {
            isPresented = false
            searchTask?.cancel()
            generation += 1
            clearResults()
            editor?.clearFindMatches()
            Task { await preview?.findClear() }
        }

        // MARK: Extras

        private func updateSuggestion(for query: FindQuery, ticket: Int) {
            guard editorCount == 0, previewCount == 0, !query.isRegex, query.text.count >= 4,
                  let editor else { return }
            let text = editor.findText
            Task { [weak self] in
                let word = await Task.detached(priority: .utility) { FindSuggestion.nearest(to: query.text, in: text) }
                    .value
                guard let self, isCurrent(ticket) else { return }
                suggestion = word
            }
        }

        private func updateStrip() {
            let length = max(1, (editor?.findText as NSString?)?.length ?? 1)
            editorStrip = Self.thin(editorRanges.map { Double($0.location) / Double(length) })
            guard let preview, previewCount > 0 else {
                previewStrip = []
                return
            }
            let ticket = generation
            Task { [weak self] in
                let positions = await preview.findPositions(limit: 400)
                guard let self, ticket == generation else { return }
                previewStrip = positions
            }
        }

        /// At most one tick per 0.2% of the strip, so 50,000 matches don't draw 50,000 ticks.
        static func thin(_ positions: [Double]) -> [Double] {
            var seen = Set<Int>()
            return positions.filter { seen.insert(Int($0 * 500)).inserted }
        }
    }
#endif
