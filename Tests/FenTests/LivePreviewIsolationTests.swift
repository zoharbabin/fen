import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Harness gate 3 for issue #2, rules 1.1/1.2/4.2: two `MarkdownTextView.Coordinator` instances
/// never share or leak live-preview styling state -- mirrors `FocusModeIsolationTests.swift`'s
/// two-instance pattern.
struct LivePreviewIsolationTests {
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
            isLivePreviewEnabled: true
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        textStorage.highlightDelegate = coordinator
        return (textView, coordinator)
    }

    /// Rule 1.1: cached styling state (the text last styled, the active caret paragraph, the
    /// image cache, checkbox/image overlays) lives on the Coordinator instance, never shared.
    @Test @MainActor
    func twoCoordinatorInstancesOverDifferentDocumentsDoNotShareLivePreviewState() throws {
        let textA = "# Heading A\n\n**bold A** paragraph."
        let textB = "# Heading B\n\n*italic B* paragraph."
        let (textViewA, coordinatorA) = makeAttachedTextView(text: textA)
        let (textViewB, coordinatorB) = makeAttachedTextView(text: textB)

        textViewA.setSelectedRange(NSRange(location: 0, length: 0))
        coordinatorA.applyLivePreviewStylingIfNeeded(in: textViewA, fullDocument: false)

        // Coordinator B never had styling applied, so it must have no cached state at all --
        // proves the two instances' livePreviewStyledText/livePreviewCaretParagraphRange fields
        // are distinct storage, not a shared/static default that A's pass would have populated.
        #expect(coordinatorA.livePreviewStyledText == textA)
        #expect(coordinatorB.livePreviewStyledText == nil)
        #expect(coordinatorB.livePreviewCaretParagraphRange == nil)

        let storageB = try #require(textViewB.textStorage)
        for index in 0 ..< storageB.length {
            #expect(
                storageB.attribute(.livePreviewTouched, at: index, effectiveRange: nil) == nil,
                "Styling coordinator A's text view must never touch coordinator B's text storage"
            )
        }
    }

    /// Rule 1.2: two windows over the *same* document text still compute and store their own
    /// independent styling state from their own text view's caret, never a value shared because
    /// the underlying document text happens to match.
    @Test @MainActor
    func twoInstancesOverTheSameDocumentTextStayIndependent() throws {
        let sharedText = "**First bold** paragraph.\n\n**Second bold** paragraph."
        let (textViewA, coordinatorA) = makeAttachedTextView(text: sharedText)
        let (textViewB, coordinatorB) = makeAttachedTextView(text: sharedText)

        let ns = sharedText as NSString
        let secondParagraphStart = ns.range(of: "**Second").location

        textViewA.setSelectedRange(NSRange(location: 0, length: 0))
        coordinatorA.applyLivePreviewStylingIfNeeded(in: textViewA, fullDocument: false)

        textViewB.setSelectedRange(NSRange(location: secondParagraphStart, length: 0))
        coordinatorB.applyLivePreviewStylingIfNeeded(in: textViewB, fullDocument: false)

        let rangeA = try #require(coordinatorA.livePreviewCaretParagraphRange)
        let rangeB = try #require(coordinatorB.livePreviewCaretParagraphRange)
        #expect(rangeA.location == 0)
        #expect(rangeB.location == secondParagraphStart)

        // A's caret sits in the first paragraph (active, left untouched); its second paragraph
        // is inactive and gets its "**" markers hidden. B's caret sits in the second paragraph
        // instead, so the touched/untouched paragraphs are exactly reversed -- proving each
        // Coordinator drove styling from its own caret, never a value shared between them.
        let storageA = try #require(textViewA.textStorage)
        let storageB = try #require(textViewB.textStorage)
        #expect(storageA.attribute(.livePreviewTouched, at: 0, effectiveRange: nil) == nil)
        #expect(storageA.attribute(.livePreviewTouched, at: secondParagraphStart, effectiveRange: nil) != nil)
        #expect(storageB.attribute(.livePreviewTouched, at: 0, effectiveRange: nil) != nil)
        #expect(storageB.attribute(.livePreviewTouched, at: secondParagraphStart, effectiveRange: nil) == nil)
    }

    /// Rule 1.2: toggling the preference on one Coordinator instance must not affect a second,
    /// independently constructed instance's styling state.
    @Test @MainActor
    func togglingPreferenceOnOneInstanceDoesNotAffectAnother() throws {
        let text = "**bold** paragraph.\n\nSecond paragraph."
        let (textViewA, coordinatorA) = makeAttachedTextView(text: text)
        let (textViewB, coordinatorB) = makeAttachedTextView(text: text)

        textViewA.setSelectedRange(NSRange(location: 0, length: 0))
        coordinatorA.applyLivePreviewStylingIfNeeded(in: textViewA, fullDocument: false)
        #expect(coordinatorA.livePreviewStyledText != nil)

        coordinatorA.parent.isLivePreviewEnabled = false
        coordinatorA.applyLivePreviewStylingIfNeeded(in: textViewA, fullDocument: true)
        #expect(coordinatorA.livePreviewStyledText == nil, "Disabling on A must clear A's own cached state")

        // B was never touched -- its own preference and cached state must be entirely unaffected
        // by A's toggle, proving the preference and derived state are per-instance.
        #expect(coordinatorB.parent.isLivePreviewEnabled == true)
        let storageB = try #require(textViewB.textStorage)
        #expect(storageB.attribute(.livePreviewTouched, at: 0, effectiveRange: nil) == nil)
    }

    /// Rule 4.2: a caret move within the same paragraph it was already in must not re-run the
    /// restyling pass at all. Proven by planting a `.livePreviewTouched` marker inside the
    /// *active* paragraph -- a spot restyling never sets one, since the active paragraph is
    /// always left plain -- so the marker can only disappear if `restyleLines` actually ran
    /// over that range. A poisoned `livePreviewCaretParagraphRange` sentinel can't do this proof:
    /// that field is always freshly recomputed from the real caret on every call, so an
    /// unreachable sentinel would just make the guard see a spurious mismatch and recompute.
    @Test @MainActor
    func rebuildIsGatedByCaretParagraphStalenessNotRunOnEveryCall() throws {
        let text = "First paragraph.\n\nSecond paragraph."
        let (textView, coordinator) = makeAttachedTextView(text: text)
        let ns = text as NSString
        let firstParagraphRange = ns.lineRange(for: NSRange(location: 0, length: 0))
        let secondParagraphStart = ns.range(of: "Second").location

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
        let activeRange = try #require(coordinator.livePreviewCaretParagraphRange)
        #expect(activeRange.location == 0)

        let textStorage = try #require(textView.textStorage)
        let markerLocation = min(firstParagraphRange.location + 2, textStorage.length - 1)
        textStorage.addAttribute(.livePreviewTouched, value: true, range: NSRange(location: markerLocation, length: 1))

        // Same paragraph, different offset within it -- the guard must skip restyling entirely,
        // leaving the marker (which restyling never sets on the active paragraph) untouched.
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
        #expect(
            textStorage.attribute(.livePreviewTouched, at: markerLocation, effectiveRange: nil) != nil,
            "Expected a same-paragraph caret move to skip restyling and leave the marker untouched"
        )

        // Moving to a genuinely different paragraph must trigger a real restyle of the paragraph
        // just vacated, clearing the marker planted on it.
        textView.setSelectedRange(NSRange(location: secondParagraphStart, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
        #expect(textStorage.attribute(.livePreviewTouched, at: markerLocation, effectiveRange: nil) == nil)
        #expect(coordinator.livePreviewCaretParagraphRange?.location == secondParagraphStart)
    }
}
