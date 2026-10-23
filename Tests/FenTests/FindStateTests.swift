import AppKit
@testable import FenCore
import Foundation
import Testing

/// A stand-in editor that records what Find asks of it.
@MainActor
final class FakeFindEditor: FindEditorTarget {
    var findText: String
    var findSelection = NSRange(location: 0, length: 0)
    var isFindFocused = false
    private(set) var shown: [(ranges: [NSRange], current: Int?, scroll: Bool)] = []
    private(set) var clears = 0
    private(set) var selectedRange: NSRange?
    private(set) var selectedRanges: [NSRange] = []
    private(set) var focusRequests = 0
    private let didReplace: () -> Void

    init(_ text: String, didReplace: @escaping () -> Void = {}) {
        findText = text
        self.didReplace = didReplace
    }

    func showFindMatches(_ ranges: [NSRange], current: Int?, scroll: Bool) {
        shown.append((ranges, current, scroll))
    }

    func clearFindMatches() {
        clears += 1
    }

    func replaceFindMatches(_ ranges: [NSRange], with strings: [String]) {
        let text = NSMutableString(string: findText)
        for (range, string) in zip(ranges, strings).reversed() {
            text.replaceCharacters(in: range, with: string)
        }
        findText = text as String
        didReplace()
    }

    func selectFindRange(_ range: NSRange) {
        selectedRange = range
    }

    func selectFindRanges(_ ranges: [NSRange]) {
        selectedRanges = ranges
    }

    func focusFindTarget() {
        focusRequests += 1
    }
}

@Suite("Find state")
@MainActor
struct FindStateTests {
    /// Opens the bar on `text`, types `query` and waits for the search to finish.
    private func opened(
        _ text: String, query: String, regex: Bool = false, selection: NSRange? = nil
    ) async throws -> (FindState, FakeFindEditor) {
        let find = FindState()
        let editor = FakeFindEditor(text)
        if let selection {
            editor.findSelection = selection
        }
        find.editor = editor
        find.visiblePanes = [.editor]
        find.isPresented = true
        find.query = FindQuery(text: query, isRegex: regex)
        find.queryChanged()
        try #require(await settled(find))
        return (find, editor)
    }

    private func settled(_ find: FindState) async throws -> Bool {
        try await pollUntilTrue { !find.isSearching }
    }

    @Test("opening the bar starts at the first match after the caret")
    func startsAtCaret() async throws {
        let find = FindState()
        let editor = FakeFindEditor("fen one fen two fen")
        editor.findSelection = NSRange(location: 5, length: 0)
        find.editor = editor
        find.visiblePanes = [.editor]
        find.present()
        find.query = FindQuery(text: "fen")
        find.queryChanged()
        try #require(await settled(find))
        #expect(find.editorCount == 3)
        #expect(find.summary == "2 of 3")
    }

    @Test("next and previous wrap around")
    func wraps() async throws {
        let (find, _) = try await opened("a b a b a", query: "a")
        #expect(find.summary == "1 of 3")
        find.previous()
        #expect(find.summary == "3 of 3")
        find.next()
        #expect(find.summary == "1 of 3")
    }

    @Test("navigation scrolls the editor to the current match and never moves the selection")
    func navigationLeavesSelection() async throws {
        let (find, editor) = try await opened("a b a", query: "a")
        find.next()
        #expect(editor.shown.last?.current == 1)
        #expect(editor.shown.last?.scroll == true)
        #expect(editor.selectedRange == nil)
        #expect(editor.selectedRanges.isEmpty)
    }

    @Test("no matches says so, and a typo suggests the nearest word")
    func noResultsAndSuggestion() async throws {
        let (find, _) = try await opened("the document is long", query: "documnet")
        #expect(find.summary == "No results")
        try #require(await pollUntilTrue { find.suggestion != nil })
        #expect(find.suggestion == "document")
    }

    @Test("an invalid regex reports itself and paints nothing")
    func invalidRegex() async throws {
        let (find, editor) = try await opened("a(b", query: "(", regex: true)
        #expect(find.summary == "Invalid pattern")
        #expect(find.hasInvalidPattern)
        #expect(editor.clears >= 1)
    }

    @Test("Esc puts the caret on the current match and clears the highlights")
    func dismissSelectsMatch() async throws {
        let find = FindState()
        let editor = FakeFindEditor("x fen y fen")
        editor.findSelection = NSRange(location: 4, length: 0)
        find.editor = editor
        find.visiblePanes = [.editor]
        find.present()
        find.query = FindQuery(text: "fen")
        find.queryChanged()
        try #require(await settled(find))
        find.dismiss()
        #expect(!find.isPresented)
        #expect(editor.selectedRange == NSRange(location: 8, length: 3))
        #expect(find.editorCount == 0)
    }

    @Test("Esc with no match returns focus to the editor")
    func dismissWithoutMatch() async throws {
        let (find, editor) = try await opened("abc", query: "zzz")
        find.dismiss()
        #expect(editor.focusRequests == 1)
        #expect(editor.selectedRange == nil)
    }

    @Test("Replace All edits through the editor once, then the bar recounts")
    func replaceAll() async throws {
        let find = FindState()
        let editor = FakeFindEditor("fen fen fen") { find.documentChanged() }
        find.editor = editor
        find.visiblePanes = [.editor]
        find.isPresented = true
        find.showsReplace = true
        find.replacement = "owl"
        find.query = FindQuery(text: "fen")
        find.queryChanged()
        try #require(await settled(find))
        find.replaceAll()
        #expect(editor.findText == "owl owl owl")
        try #require(await pollUntilTrue { find.editorCount == 0 && !find.isSearching })
    }

    @Test("Replace swaps only the current match")
    func replaceCurrent() async throws {
        let find = FindState()
        let editor = FakeFindEditor("fen fen") { find.documentChanged() }
        find.editor = editor
        find.visiblePanes = [.editor]
        find.isPresented = true
        find.showsReplace = true
        find.replacement = "owl"
        find.query = FindQuery(text: "fen")
        find.queryChanged()
        try #require(await settled(find))
        find.replaceCurrent()
        #expect(editor.findText == "owl fen")
    }

    @Test("a regex replacement previews with its groups expanded")
    func replacementPreview() async throws {
        let find = FindState()
        let editor = FakeFindEditor("me@fen")
        find.editor = editor
        find.visiblePanes = [.editor]
        find.isPresented = true
        find.showsReplace = true
        find.replacement = "$2:$1"
        find.query = FindQuery(text: "(\\w+)@(\\w+)", isRegex: true)
        find.queryChanged()
        try #require(await settled(find))
        #expect(find.replacementPreview == "fen:me")
        withExtendedLifetime(editor) {}
    }

    @Test("select all matches hands every range to the editor and closes the bar")
    func selectAll() async throws {
        let (find, editor) = try await opened("a b a", query: "a")
        find.selectAllMatches()
        #expect(editor.selectedRanges.count == 2)
        #expect(!find.isPresented)
    }

    @Test("select all matches also clears the editor highlights")
    func selectAllClearsHighlights() async throws {
        let (find, editor) = try await opened("a b a", query: "a")
        let before = editor.clears
        find.selectAllMatches()
        #expect(editor.clears == before + 1)
    }

    @Test("Replace All uses the text and query as they are now, not the last finished search")
    func replaceAllIgnoresStaleResults() async throws {
        let find = FindState()
        let editor = FakeFindEditor("fen bar") { find.documentChanged() }
        find.editor = editor
        find.visiblePanes = [.editor]
        find.isPresented = true
        find.showsReplace = true
        find.replacement = "owl"
        find.query = FindQuery(text: "fen")
        find.queryChanged()
        try #require(await settled(find))
        find.query = FindQuery(text: "bar")
        find.queryChanged()
        find.replaceAll()
        #expect(editor.findText == "fen owl")
    }

    @Test("find in selection stays inside the selection")
    func inSelection() async throws {
        let find = FindState()
        let editor = FakeFindEditor("fen fen fen")
        editor.findSelection = NSRange(location: 4, length: 3)
        find.editor = editor
        find.visiblePanes = [.editor]
        find.isPresented = true
        find.inSelection = true
        find.inSelectionChanged()
        find.query = FindQuery(text: "fen")
        find.queryChanged()
        try #require(await settled(find))
        #expect(find.editorCount == 1)
    }

    @Test("a preview-only window does not search the editor")
    func previewOnlySkipsEditor() async throws {
        let find = FindState()
        let editor = FakeFindEditor("fen")
        find.editor = editor
        find.visiblePanes = [.preview]
        find.isPresented = true
        find.query = FindQuery(text: "fen")
        find.queryChanged()
        try #require(await settled(find))
        #expect(find.editorCount == 0)
        #expect(find.activePane == .preview)
        #expect(!find.canReplace)
    }

    @Test("closing the bar ignores a search still in flight")
    func dismissCancelsSearch() async throws {
        let (find, _) = try await opened("fen", query: "fen")
        find.query.text = "f"
        find.queryChanged()
        find.dismiss()
        try #require(await settled(find))
        #expect(find.editorCount == 0)
        #expect(!find.isPresented)
    }

    @Test("the first match at or after an anchor wraps to the start")
    func indexAtOrAfter() {
        #expect(FindState.index(atOrAfter: 5, in: [1, 5, 9]) == 1)
        #expect(FindState.index(atOrAfter: 6, in: [1, 5, 9]) == 2)
        #expect(FindState.index(atOrAfter: 10, in: [1, 5, 9]) == 0)
        #expect(FindState.index(atOrAfter: 0, in: []) == nil)
    }

    @Test("strip ticks thin out to one per 0.2 percent")
    func thinStrip() {
        let many = (0 ..< 10000).map { Double($0) / 10000 }
        #expect(FindState.thin(many).count <= 501)
        #expect(FindState.thin([0.1, 0.1001]).count == 1)
    }
}

@Suite("Find suggestion")
struct FindSuggestionTests {
    @Test("finds the nearest common word")
    func nearest() {
        #expect(FindSuggestion.nearest(to: "recieve", in: "we receive and receive; also relieve") == "receive")
    }

    @Test("a short query tolerates one typo, not two")
    func shortQuery() {
        #expect(FindSuggestion.nearest(to: "crate", in: "a cat") == nil)
        #expect(FindSuggestion.nearest(to: "cate", in: "a cat") == "cat")
    }

    @Test("an exact word and a phrase never suggest")
    func noSuggestion() {
        #expect(FindSuggestion.nearest(to: "receive", in: "receive") == nil)
        #expect(FindSuggestion.nearest(to: "recieve it", in: "receive it") == nil)
    }

    @Test("accents and case do not count as typos")
    func folds() {
        #expect(FindSuggestion.nearest(to: "resumee", in: "Résumé résumé") == "resume")
    }
}
