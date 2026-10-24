import AppKit
@testable import FenCore
import Highlightr
import Testing

/// Find against a real `MarkdownNSTextView` and its coordinator, wired to a real `FindState`.
@Suite("Find in the editor")
@MainActor
struct FindEditorTargetTests {
    private struct Harness {
        let textView: MarkdownNSTextView
        let coordinator: MarkdownTextView.Coordinator
        let find: FindState
        let window: NSWindow
    }

    private func makeHarness(_ text: String, livePreview: Bool = false) -> Harness {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let storage = CodeAttributedString()
        storage.language = "markdown"
        storage.highlightr.setTheme(to: "xcode")
        let layoutManager = livePreview ? DecorationLayoutManager() : NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        textView.isEditable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = font
        textView.string = text
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        let find = FindState()
        let parent = MarkdownTextView(
            text: .constant(text), font: font, highlightThemeName: "xcode", lineSpacing: 0, horizontalInset: 0,
            verticalInset: 0, isEditable: true, scrollsPastEnd: false, isLivePreviewEnabled: livePreview,
            documentURL: nil
        ).finding(find)
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        storage.highlightDelegate = coordinator
        textView.delegate = coordinator
        find.editor = coordinator
        find.visiblePanes = [.editor]
        return Harness(textView: textView, coordinator: coordinator, find: find, window: window)
    }

    private func search(_ harness: Harness, _ query: String, regex: Bool = false) async throws {
        harness.find.isPresented = true
        harness.find.query = FindQuery(text: query, isRegex: regex)
        harness.find.queryChanged()
        try #require(await pollUntilTrue { !harness.find.isSearching })
    }

    private func background(at location: Int, in harness: Harness) -> NSColor? {
        harness.textView.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: location, effectiveRange: nil
        ) as? NSColor
    }

    @Test("matches get a highlight, the current one a different color, and clearing removes both")
    func paintsAndClears() async throws {
        let harness = makeHarness("fen and fen")
        try await search(harness, "fen")
        let first = try #require(background(at: 0, in: harness))
        let second = try #require(background(at: 8, in: harness))
        #expect(first != second)
        #expect(background(at: 4, in: harness) == nil)
        harness.find.dismiss()
        #expect(background(at: 0, in: harness) == nil)
        #expect(background(at: 8, in: harness) == nil)
    }

    @Test(
        "highlights show on screen, with and without Live Preview: current orange, others yellow, other text clear",
        arguments: [false, true]
    )
    func highlightsAreVisible(livePreview: Bool) async throws {
        let harness = makeHarness("fen one\n\nfen two\n\nplain words here", livePreview: livePreview)
        harness.window.orderBack(nil)
        harness.textView.layoutSubtreeIfNeeded()
        try await search(harness, "fen")
        let textView = harness.textView
        let layout = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / Double(textView.bounds.width)

        func colors(at characters: NSRange) -> [(r: Double, g: Double, b: Double)] {
            // A row just inside the bottom edge of the characters' box, where glyphs rarely draw.
            let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let y = Int((box.maxY - 2) * scale)
            return stride(from: box.minX + 1, to: box.maxX - 1, by: 1).compactMap { x in
                rep.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.sRGB).map {
                    (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent))
                }
            }
        }
        func tint(_ list: [(r: Double, g: Double, b: Double)]) -> (warmth: Double, greenShare: Double) {
            // The most orange-or-yellow pixel in the row: red minus blue, whatever the page color is.
            let best = list.max { $0.r - $0.b < $1.r - $1.b } ?? (0, 0, 0)
            return (best.r - best.b, best.g / max(best.r, 0.01))
        }
        let text = textView.string as NSString
        let current = tint(colors(at: NSRange(location: 0, length: 3)))
        let other = tint(colors(at: NSRange(location: 9, length: 3)))
        let plain = tint(colors(at: text.range(of: "plain")))
        #expect(current.warmth > plain.warmth + 0.2)
        #expect(other.warmth > plain.warmth + 0.2)
        // Yellow has more green in it than orange does.
        #expect(current.greenShare < other.greenShare)
    }

    @Test("showing matches, and moving between them, leaves the caret and selection alone")
    func navigationKeepsSelection() async throws {
        let harness = makeHarness("fen and fen and fen")
        harness.textView.setSelectedRange(NSRange(location: 4, length: 0))
        try await search(harness, "fen")
        harness.find.next()
        harness.find.next()
        #expect(harness.textView.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test("Replace All is one undo step with a Replace All name")
    func replaceAllUndoes() async throws {
        let harness = makeHarness("fen fen fen")
        harness.window.makeFirstResponder(harness.textView)
        try await search(harness, "fen")
        harness.find.replacement = "owl"
        harness.find.replaceAll()
        #expect(harness.textView.string == "owl owl owl")
        #expect(harness.textView.undoManager?.undoActionName == "Replace All")
        harness.textView.undoManager?.undo()
        #expect(harness.textView.string == "fen fen fen")
    }

    @Test("an edit refreshes the matches")
    func editRefreshes() async throws {
        let harness = makeHarness("fen")
        try await search(harness, "fen")
        harness.textView.insertText(" fen", replacementRange: NSRange(location: 3, length: 0))
        try #require(await pollUntilTrue { harness.find.editorCount == 2 && !harness.find.isSearching })
    }

    @Test("Replace swaps the current match and puts the caret after it")
    func replaceCurrent() async throws {
        let harness = makeHarness("fen and fen")
        try await search(harness, "fen")
        harness.find.replacement = "owl"
        harness.find.replaceCurrent()
        #expect(harness.textView.string == "owl and fen")
        #expect(harness.textView.undoManager?.undoActionName == "Replace")
        try #require(await pollUntilTrue { harness.find.editorCount == 1 && !harness.find.isSearching })
    }

    @Test("Esc selects the current match")
    func escSelectsMatch() async throws {
        let harness = makeHarness("one fen two")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.find.present()
        harness.find.query = FindQuery(text: "fen")
        harness.find.queryChanged()
        try #require(await pollUntilTrue { !harness.find.isSearching })
        harness.find.dismiss()
        #expect(harness.textView.selectedRange() == NSRange(location: 4, length: 3))
    }

    @Test("select all matches makes one multi-range selection")
    func selectAll() async throws {
        let harness = makeHarness("fen fen")
        try await search(harness, "fen")
        harness.find.selectAllMatches()
        #expect(harness.textView.selectedRanges.count == 2)
    }

    @Test("a match inside a Live Preview line paints without un-rendering the line")
    func livePreviewUntouched() async throws {
        let harness = makeHarness("# Title with fen\n\nbody fen", livePreview: true)
        harness.textView.setSelectedRange(NSRange(location: 22, length: 0))
        try await search(harness, "fen")
        harness.find.next()
        #expect(harness.textView.selectedRange() == NSRange(location: 22, length: 0))
        #expect(background(at: 13, in: harness) != nil)
    }
}
