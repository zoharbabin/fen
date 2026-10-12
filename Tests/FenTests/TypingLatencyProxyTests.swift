import AppKit
@testable import FenCore
import Foundation
import Highlightr
import SwiftUI
import Testing

/// Headless proxy for issue #35's "no regression in typing latency" bar. It is not a measurement of
/// typing in the app.
///
/// It types into a real `MarkdownNSTextView` (the coordinator is its delegate, live preview is on)
/// holding a 5000-line note, through `insertText`, the same entry point a key press reaches. For each
/// key it records two main-thread costs: the synchronous edit (`textDidChange` and everything it
/// calls), and the longest block that runs on the main thread while the edit's syntax highlight comes
/// back and is applied. The second is the longest gap of a main-actor ticker, so it also shows any
/// other main-thread work that lands in that window, such as indexing hand-offs. The limits are loose
/// on purpose: they catch a regression of an order of magnitude, not noise between machines. The
/// numbers are printed (`PERF typing ...`) and recorded in `docs/spikes/latency-proxies.md`.
///
/// Not covered: key event dispatch, text layout and drawing (the window is never shown), the preview
/// pane, and the SwiftUI update after the binding changes.
@Suite("Typing latency proxy (issue #35)", .serialized)
@MainActor
struct TypingLatencyProxyTests {
    /// Counts finished highlight passes and forwards to the coordinator, which is the real delegate.
    @MainActor private final class HighlightCounter: NSObject, HighlightDelegate {
        let target: MarkdownTextView.Coordinator
        private(set) var landed = 0

        init(target: MarkdownTextView.Coordinator) {
            self.target = target
        }

        /// Highlightr calls this on the main queue.
        nonisolated func didHighlight(_ range: NSRange, success: Bool) {
            MainActor.assumeIsolated {
                landed += 1
                target.didHighlight(range, success: success)
            }
        }
    }

    /// A task on the main actor that only yields. Its longest gap is the longest block of main-thread
    /// work that ran in between, whoever it came from (the key presses here count too).
    private final class Ticker {
        private(set) var longestGap = Duration.zero
        private var task: Task<Void, Never>?

        @MainActor func start() {
            task = Task { @MainActor in
                let clock = ContinuousClock()
                var last = clock.now
                while !Task.isCancelled {
                    await Task.yield()
                    let now = clock.now
                    self.longestGap = max(self.longestGap, now - last)
                    last = now
                }
            }
        }

        @MainActor func stop() {
            task?.cancel()
        }
    }

    private struct Editor {
        let textView: MarkdownNSTextView
        let counter: HighlightCounter
        let window: NSWindow
    }

    private struct Keystroke {
        var edit: Duration
        var afterwards: Duration
        var total: Duration {
            edit + afterwards
        }
    }

    private func makeNote(lines: Int) -> String {
        var note = ""
        var block = 0
        while note.reduce(0, { $1 == "\n" ? $0 + 1 : $0 }) < lines {
            note += "# Heading \(block)\n\nSome **bold** and *italic* text with `code` and [link](http://x.y).\n\n"
            note += "- item one\n- item two\n  - nested\n\n| a | b |\n|---|---|\n| \(block) | **x** |\n\n"
            note += "```swift\nlet x = \(block)\n```\n\n---\n\n> quote\n\n"
            block += 1
        }
        return note
    }

    private func makeEditor(note: String, livePreview: Bool) async throws -> Editor {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let storage = CodeAttributedString()
        storage.language = "markdown"
        storage.highlightr.setTheme(to: "xcode")
        let layoutManager = DecorationLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), textContainer: container)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = font
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        var bound = note
        let parent = MarkdownTextView(
            text: Binding(get: { bound }, set: { bound = $0 }),
            font: font,
            highlightThemeName: "xcode",
            lineSpacing: 0,
            horizontalInset: 0,
            verticalInset: 0,
            isEditable: true,
            scrollsPastEnd: false,
            isLivePreviewEnabled: livePreview,
            documentURL: nil
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        textView.delegate = coordinator
        let counter = HighlightCounter(target: coordinator)
        storage.highlightDelegate = counter
        window.makeFirstResponder(textView)

        textView.string = note
        let first = try await pollUntilTrue(timeout: .seconds(60)) { counter.landed >= 1 }
        try #require(first, "the first highlight pass never landed")
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
        // A caret in the middle of the note, at the start of a text paragraph.
        let middle = (note as NSString).range(of: "Some **bold**", options: [], range: NSRange(
            location: note.utf16.count / 2, length: note.utf16.count / 2
        ))
        textView.setSelectedRange(NSRange(location: middle.location, length: 0))
        return Editor(textView: textView, counter: counter, window: window)
    }

    /// One key press: the synchronous edit, then wait for its highlight to land and be applied.
    private func type(_ character: String, in editor: Editor) async -> Keystroke? {
        let clock = ContinuousClock()
        let landedBefore = editor.counter.landed
        let begin = clock.now
        editor.textView.insertText(character, replacementRange: editor.textView.selectedRange())
        var last = clock.now
        let edit = last - begin
        var gap = Duration.zero
        while editor.counter.landed == landedBefore {
            await Task.yield()
            let now = clock.now
            gap = max(gap, now - last)
            last = now
            if now - begin > .seconds(10) {
                return nil
            }
        }
        return Keystroke(edit: edit, afterwards: gap)
    }

    private func percentile(_ sorted: [Duration], _ fraction: Double) -> Duration {
        sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    private func report(_ label: String, _ strokes: [Keystroke]) -> String {
        func row(_ name: String, _ values: [Duration]) -> String {
            let sorted = values.sorted()
            let median = percentile(sorted, 0.5).fractionalMilliseconds
            let p95 = percentile(sorted, 0.95).fractionalMilliseconds
            let worst = sorted[sorted.count - 1].fractionalMilliseconds
            return "\(name) median \(median) / p95 \(p95) / max \(worst) ms"
        }
        return "PERF typing \(label), \(strokes.count) keys: " + row("edit", strokes.map(\.edit)) + "; "
            + row("highlight-apply gap", strokes.map(\.afterwards)) + "; " + row("edit+gap", strokes.map(\.total))
    }

    private func typeKeys(
        _ count: Int,
        in editor: Editor,
        while condition: () -> Bool = { true }
    ) async -> [Keystroke] {
        var strokes: [Keystroke] = []
        let alphabet = Array("abcdefghij klmnop")
        for number in 0 ..< count where condition() {
            if let stroke = await type(String(alphabet[number % alphabet.count]), in: editor) {
                strokes.append(stroke)
            }
        }
        return strokes
    }

    @Test("typing in a 5000-line note while nothing else runs")
    func idle() async throws {
        let note = makeNote(lines: 5000)
        #expect(note.split(separator: "\n", omittingEmptySubsequences: false).count >= 5000)
        let editor = try await makeEditor(note: note, livePreview: false)
        _ = await typeKeys(20, in: editor) // warm up
        var all: [Keystroke] = []
        for _ in 0 ..< 3 {
            all += await typeKeys(100, in: editor)
        }
        print(report("5000-line note, idle", all))
        #expect(all.count >= 290, "some keys never finished highlighting")
        let sorted = all.map(\.total).sorted()
        #expect(percentile(sorted, 0.5) < .milliseconds(Limits.median), "median \(percentile(sorted, 0.5))")
        #expect(percentile(sorted, 0.95) < .milliseconds(Limits.p95), "p95 \(percentile(sorted, 0.95))")
        #expect(sorted[sorted.count - 1] < .milliseconds(Limits.max), "max \(sorted[sorted.count - 1])")
        withExtendedLifetime(editor.window) {}
    }

    /// Live Preview is off by default and labeled Experimental. A text change restyles the whole note
    /// (`applyLivePreviewStylingIfNeeded`), so each key costs time in proportion to the note's length.
    /// The ceiling only catches it getting much worse.
    @Test("typing in a 5000-line note with Live Preview on")
    func livePreview() async throws {
        let editor = try await makeEditor(note: makeNote(lines: 5000), livePreview: true)
        _ = await typeKeys(3, in: editor) // warm up
        let strokes = await typeKeys(30, in: editor)
        print(report("5000-line note, Live Preview on", strokes))
        #expect(strokes.count >= 29, "some keys never finished highlighting")
        let sorted = strokes.map(\.total).sorted()
        #expect(percentile(sorted, 0.5) < .milliseconds(Limits.livePreviewMedian), "median \(percentile(sorted, 0.5))")
        withExtendedLifetime(editor.window) {}
    }

    @Test("typing in a 5000-line note while three workspaces of 2000 files are listed and indexed")
    func whileIndexing() async throws {
        let note = makeNote(lines: 5000)
        let editor = try await makeEditor(note: note, livePreview: false)
        _ = await typeKeys(20, in: editor)

        let fixture = try Fixture(workspaces: 3, files: 2000)
        defer { fixture.cleanUp() }
        let library = fixture.library
        let ids = fixture.ids
        func busy() -> Bool {
            !ids.allSatisfy {
                let status = library.indexStatus(for: $0)
                return library.state(for: $0).hasScanned && status.phase == .idle && status.documents == 2000
            }
        }
        // All workspaces are listed and at least one is still building its index.

        func indexing() -> Bool {
            ids.allSatisfy { library.state(for: $0).hasScanned }
                && ids.contains { library.indexStatus(for: $0).phase != .idle }
        }

        let ticker = Ticker()
        ticker.start()
        var during: [Keystroke] = []
        var indexingOnly: [Keystroke] = []
        let typingStarted = ContinuousClock.now
        while busy(), ContinuousClock.now - typingStarted < .seconds(150) {
            let inIndexing = indexing()
            let strokes = await typeKeys(25, in: editor, while: busy)
            during += strokes
            if inIndexing {
                indexingOnly += strokes
            }
        }
        ticker.stop()
        #expect(indexingOnly.count >= 100, "indexing finished too early to measure: \(indexingOnly.count) keys")
        print(report("5000-line note, 3 workspaces x 2000 files, while listing or indexing", during))
        print(report("5000-line note, 3 workspaces x 2000 files, while indexing only", indexingOnly))
        let longest = ticker.longestGap.fractionalMilliseconds
        print("PERF typing longest main-actor block while indexing and typing: \(longest) ms")
        #expect(ticker.longestGap < .milliseconds(Limits.max), "longest block \(ticker.longestGap)")
        let sorted = during.map(\.total).sorted()
        #expect(percentile(sorted, 0.5) < .milliseconds(Limits.median), "median \(percentile(sorted, 0.5))")
        #expect(percentile(sorted, 0.95) < .milliseconds(Limits.p95), "p95 \(percentile(sorted, 0.95))")
        #expect(sorted[sorted.count - 1] < .milliseconds(Limits.max), "max \(sorted[sorted.count - 1])")

        // Let the indexing finish so the folders can be deleted.
        let finished = try await pollUntilTrue(timeout: .seconds(300)) { !busy() }
        #expect(finished, "indexing did not finish")
        library.search.closeAll()
        withExtendedLifetime(editor.window) {}
    }

    /// Workspaces of cloned notes, added to a library with real file watchers. Adding starts the scan.
    @MainActor private final class Fixture {
        let library: WorkspaceLibrary
        let ids: [UUID]
        private let home: TempFolder
        private let folders: [TempFolder]

        init(workspaces: Int, files: Int) throws {
            home = try TempFolder("typing-proxy-home")
            let template = try TempFolder("typing-proxy-template")
            defer { template.cleanUp() }
            try Self.populate(template, files: files)
            folders = try (0 ..< workspaces).map { _ in
                let parent = try TempFolder("typing-proxy")
                try FileManager.default.copyItem(at: template.root, to: parent.root.appendingPathComponent("notes"))
                return parent
            }
            let library = WorkspaceLibrary(
                home: FenHome(root: home.root.appendingPathComponent(".fen")), watching: true, embedder: FakeEmbedder()
            )
            ids = try folders.map { try library.add(folder: $0.root.appendingPathComponent("notes")).id }
            self.library = library
        }

        func cleanUp() {
            library.search.closeAll()
            home.cleanUp()
            folders.forEach { $0.cleanUp() }
        }

        private static func populate(_ folder: TempFolder, files: Int) throws {
            let words = [
                "release",
                "notarize",
                "garden",
                "budget",
                "travel",
                "recipe",
                "meeting",
                "backup",
                "sleep",
                "cache",
            ]
            for index in 0 ..< files {
                let body = (0 ..< 40).map { words[($0 * 7 + index * 3) % words.count] + String(($0 + index) % 13) }
                    .joined(separator: " ")
                try folder.write(
                    "section-\(index / 25)/note-\(index).md",
                    "# Note \(index)\n\n\(body).\n\n## Part two\n\n\(body).\n"
                )
            }
        }
    }

    /// Loose regression ceilings in milliseconds. See `docs/spikes/latency-proxies.md`.
    private enum Limits {
        static let median = 100
        static let p95 = 250
        static let max = 1000
        static let livePreviewMedian = 5000
    }
}

extension Duration {
    var fractionalMilliseconds: String {
        String(format: "%.1f", Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
}
