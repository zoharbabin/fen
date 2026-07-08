import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Reproduces "zoom in/out sometimes loses scroll-sync": zooming changes `preferences.fontSize`,
/// which changes the editor's *real* font and line height (unlike the preview, which only scales
/// via CSS), but `ScrollSync.editorScrollFraction` itself never changes during a zoom step -- zoom
/// writes straight to `Preferences.fontSize` and never calls `ScrollSync.editorDidScroll`/
/// `previewDidScroll`. `Coordinator.applyScrollFraction`'s dedup guard only compares the incoming
/// *fraction* against the last one it applied, so when a zoom step leaves that fraction unchanged,
/// the guard skips reapplying the scroll position entirely -- even though the font change just
/// altered the document's total laid-out height underneath it, leaving the editor's pixel offset
/// stale relative to the fraction it's supposed to represent. The preview's `fontScaleAssignmentJS`
/// re-derives its scroll target against the newly-scaled layout on every zoom step; the editor's
/// `Coordinator` has no equivalent, so it drifts out of sync with the preview after a zoom.
@Suite("Editor font-size zoom keeps its scroll fraction accurate")
struct EditorFontSizeScrollSyncVerifyTest {
    @MainActor
    private func makeEditorScrollView(font: NSFont, text: String) -> (NSScrollView, MarkdownNSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true

        let textStorage = CodeAttributedString()
        textStorage.language = "markdown"
        textStorage.highlightr.setTheme(to: "xcode")
        textStorage.highlightr.theme.setCodeFont(font)

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = MarkdownNSTextView(frame: .zero, textContainer: textContainer)
        textView.scrollsPastEnd = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = font
        textView.textContainerInset = NSSize.zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.string = text

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    /// Mirrors `updateNSView`'s font-change branch exactly: `CodeAttributedString`'s syntax
    /// highlighting sets an explicit font attribute per run, so just assigning `textView.font`
    /// (as this test's first draft did) doesn't actually change the laid-out text's font --
    /// only `setCodeFont` plus forcing a full rehighlight does.
    @MainActor
    private func applyFontChange(_ font: NSFont, to textView: MarkdownNSTextView) throws {
        let textStorage = try #require(textView.textStorage as? CodeAttributedString)
        textStorage.highlightr.theme.setCodeFont(font)
        textView.font = font
        let language = textStorage.language
        textStorage.language = nil
        textStorage.language = language
    }

    @Test("Reapplying the same fraction after a font-size zoom lands on the correct pixel offset")
    @MainActor
    func fontSizeZoomKeepsFractionAccurate() throws {
        let text = (1 ... 120).map { "Line \($0) of the document body." }.joined(separator: "\n")
        let smallFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let (scrollView, textView) = makeEditorScrollView(font: smallFont, text: text)

        // Attach to a real window so the text view actually lays out and reports a
        // meaningful contentView.bounds.height -- an unattached view never gets real geometry.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        scrollView.layoutSubtreeIfNeeded()

        let parent = MarkdownTextView(
            text: .constant(text),
            font: smallFont,
            highlightThemeName: "xcode",
            lineSpacing: 0,
            horizontalInset: 0,
            verticalInset: 0,
            isEditable: true,
            scrollsPastEnd: false,
            scrollFraction: 0.5,
            isScrollSyncEnabled: true
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView

        let heightBefore = try #require(textView.layoutManager).usedRect(for: try #require(textView.textContainer))
            .height
        #expect(heightBefore > 200, "Expected the 120-line document to overflow a 200pt-tall viewport")

        coordinator.applyScrollFraction(0.5, to: scrollView)
        let maxScrollBefore = textView.contentHeightExcludingScrollPastEnd - scrollView.contentView.bounds.height
        #expect(maxScrollBefore > 0, "Expected the document to still overflow after the initial scroll")
        let pixelYBefore = scrollView.contentView.bounds.origin.y
        #expect(pixelYBefore > 0, "Expected the initial 0.5 fraction to move the scroll offset off zero")

        // Simulate a zoom step: grow the font the same way `updateNSView` does, which grows
        // every line's height and the document's total laid-out height -- without touching
        // `ScrollSync`, so the fraction passed back in below is unchanged.
        let bigFont = NSFont.monospacedSystemFont(ofSize: 40, weight: .regular)
        try applyFontChange(bigFont, to: textView)
        try #require(textView.layoutManager).ensureLayout(for: try #require(textView.textContainer))

        let totalHeightAfter = textView.contentHeightExcludingScrollPastEnd
        let visibleHeight = scrollView.contentView.bounds.height
        #expect(
            totalHeightAfter > maxScrollBefore + visibleHeight,
            "Expected growing the font to meaningfully grow the document's total laid-out height"
        )

        // Mirrors updateNSView's final call after a font change: same fraction, unchanged since
        // ScrollSync was never touched by the zoom.
        coordinator.applyScrollFraction(0.5, to: scrollView)

        let maxScrollAfter = totalHeightAfter - visibleHeight
        let pixelYAfter = scrollView.contentView.bounds.origin.y
        let effectiveFractionAfter = pixelYAfter / maxScrollAfter

        #expect(
            abs(effectiveFractionAfter - 0.5) < 0.05,
            """
            Expected the editor's scroll position to still represent ~0.5 of the document after \
            the font-size zoom (got \(effectiveFractionAfter), pixelY=\(pixelYAfter), \
            maxScroll=\(maxScrollAfter)) -- a mismatch means the zoom left the editor's pixel \
            offset stale relative to its intended fraction, desyncing it from the preview
            """
        )
    }
}
