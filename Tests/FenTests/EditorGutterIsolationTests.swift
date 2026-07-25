import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Harness gate 3 for issue #21, rules 1.1/1.2: two `MarkdownTextView.Coordinator` instances
/// never share or leak `gutterLineStartOffsets` -- mirrors `FocusModeIsolationTests.swift`'s
/// two-instance pattern.
struct EditorGutterIsolationTests {
    @MainActor
    private func makeAttachedTextView(text: String) -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let textStorage = CodeAttributedString()
        textStorage.language = "markdown"
        textStorage.highlightr.setTheme(to: "xcode")

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)

        let textView = MarkdownNSTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            textContainer: textContainer
        )
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = font
        textView.string = text

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView

        let parent = MarkdownTextView(
            text: .constant(text),
            font: font,
            highlightThemeName: "xcode",
            lineSpacing: 0,
            horizontalInset: 0,
            verticalInset: 0,
            isEditable: true,
            scrollsPastEnd: false,
            showLineNumbers: true
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        textStorage.highlightDelegate = coordinator
        return (textView, coordinator)
    }

    @Test @MainActor
    func twoCoordinatorInstancesOverDifferentDocumentsDoNotShareGutterState() {
        let textA = "Line one A\nLine two A\nLine three A"
        let textB = "Different\nDocument\nEntirely\nWith more lines\nThan A"
        let (textViewA, coordinatorA) = makeAttachedTextView(text: textA)
        let (textViewB, coordinatorB) = makeAttachedTextView(text: textB)

        coordinatorA.refreshGutterLineStartOffsetsIfNeeded(text: textViewA.string)
        coordinatorB.refreshGutterLineStartOffsetsIfNeeded(text: textViewB.string)

        #expect(coordinatorA.gutterLineStartOffsets != coordinatorB.gutterLineStartOffsets)
        #expect(coordinatorA.gutterLineStartOffsets == computeLineStartOffsets(text: textA))
        #expect(coordinatorB.gutterLineStartOffsets == computeLineStartOffsets(text: textB))
    }

    @Test @MainActor
    func twoInstancesOverTheSameDocumentTextStayIndependent() {
        let sharedText = "First\nSecond\nThird"
        let (textViewA, coordinatorA) = makeAttachedTextView(text: sharedText)
        let (textViewB, coordinatorB) = makeAttachedTextView(text: sharedText)

        coordinatorA.refreshGutterLineStartOffsetsIfNeeded(text: textViewA.string)
        // Coordinator B never had a refresh triggered, so it must still be at its initial
        // empty state -- proves the two instances' gutterLineStartOffsets fields are distinct
        // storage, not a shared/static default that A's refresh would have populated for both.
        #expect(!coordinatorA.gutterLineStartOffsets.isEmpty)
        #expect(coordinatorB.gutterLineStartOffsets.isEmpty)

        coordinatorB.refreshGutterLineStartOffsetsIfNeeded(text: textViewB.string)
        #expect(coordinatorA.gutterLineStartOffsets == coordinatorB.gutterLineStartOffsets)

        // Mutating A's text (and refreshing only A) must never touch B's already-cached table.
        let mutatedText = sharedText + "\nFourth"
        textViewA.string = mutatedText
        coordinatorA.refreshGutterLineStartOffsetsIfNeeded(text: mutatedText)
        #expect(coordinatorA.gutterLineStartOffsets != coordinatorB.gutterLineStartOffsets)
        #expect(coordinatorB.gutterLineStartOffsets == computeLineStartOffsets(text: sharedText))
    }

    /// Rule 4.2 (issue #21): a refresh call whose text matches the last-built `gutterText`
    /// must skip recomputation entirely, not just happen to produce the same table. Proven by
    /// planting a sentinel value the real recompute would never produce, then calling refresh
    /// again with unchanged text -- if the guard didn't gate the rebuild, the sentinel would be
    /// overwritten with the real (different) table.
    @Test @MainActor
    func rebuildIsGatedByTextStalenessNotRunOnEveryCall() {
        let text = "First\nSecond\nThird"
        let (textView, coordinator) = makeAttachedTextView(text: text)

        coordinator.refreshGutterLineStartOffsetsIfNeeded(text: textView.string)
        #expect(coordinator.gutterLineStartOffsets == computeLineStartOffsets(text: text))

        let sentinel = [-1, -2, -3]
        coordinator.gutterLineStartOffsets = sentinel
        coordinator.refreshGutterLineStartOffsetsIfNeeded(text: textView.string)
        #expect(
            coordinator.gutterLineStartOffsets == sentinel,
            "Expected the unchanged-text refresh to skip recomputation and leave the sentinel untouched"
        )

        let mutatedText = text + "\nFourth"
        textView.string = mutatedText
        coordinator.refreshGutterLineStartOffsetsIfNeeded(text: mutatedText)
        #expect(
            coordinator.gutterLineStartOffsets == computeLineStartOffsets(text: mutatedText),
            "Expected a genuine text change to still trigger a real recompute"
        )
    }
}
