import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Unit/integration tests for issue #19's focus/typewriter mode, proving each numbered rule
/// from the spec comment on https://github.com/zoharbabin/fen/issues/19.
@Suite("Focus/typewriter mode")
struct FocusModeTests {
    // MARK: - Pure-function edge cases (FocusModeEditing)

    @Test("An empty document produces a zero-length active range and no dim ranges, without crashing")
    func emptyDocumentProducesNoDimRangesOrCenteringCrash() {
        let activeRange = FocusModeEditing.activeParagraphRange(text: "", caretLocation: 0)
        #expect(activeRange == NSRange(location: 0, length: 0))
        #expect(FocusModeEditing.dimmedRanges(text: "", activeRange: activeRange).isEmpty)
        #expect(FocusModeEditing.centeringOffset(caretLineTop: 0, visibleHeight: 400) == 0)
    }

    @Test("A single-paragraph document has an active range spanning the whole document and nothing to dim")
    func singleLineDocumentDimsNothing() {
        let text = "Just one paragraph, no blank lines anywhere in it."
        let activeRange = FocusModeEditing.activeParagraphRange(text: text, caretLocation: 5)
        #expect(activeRange == NSRange(location: 0, length: (text as NSString).length))
        #expect(FocusModeEditing.dimmedRanges(text: text, activeRange: activeRange).isEmpty)
    }

    @Test("A caret at the very start of the document resolves a valid in-bounds active range")
    func caretAtDocumentStartResolvesValidRange() {
        let text = "First paragraph.\n\nSecond paragraph."
        let activeRange = FocusModeEditing.activeParagraphRange(text: text, caretLocation: 0)
        let ns = text as NSString
        #expect(activeRange.location == 0)
        #expect(NSMaxRange(activeRange) <= ns.length)
        #expect(ns.substring(with: activeRange) == "First paragraph.\n")
    }

    @Test("A caret at the very end of the document resolves a valid in-bounds active range")
    func caretAtDocumentEndResolvesValidRange() {
        let text = "First paragraph.\n\nSecond paragraph."
        let ns = text as NSString
        let activeRange = FocusModeEditing.activeParagraphRange(text: text, caretLocation: ns.length)
        #expect(NSMaxRange(activeRange) <= ns.length)
        #expect(ns.substring(with: activeRange) == "Second paragraph.")
    }

    @Test("A caret at the end of a document with a trailing newline resolves a valid in-bounds active range")
    func caretAtDocumentEndWithTrailingNewlineResolvesValidRange() {
        let text = "First paragraph.\n\nSecond paragraph.\n"
        let ns = text as NSString
        let activeRange = FocusModeEditing.activeParagraphRange(text: text, caretLocation: ns.length)
        #expect(activeRange.location >= 0)
        #expect(NSMaxRange(activeRange) <= ns.length)
    }

    @Test("A caret beyond the document's end is clamped rather than producing an out-of-range range")
    func caretPastDocumentEndIsClamped() {
        let text = "One paragraph."
        let ns = text as NSString
        let activeRange = FocusModeEditing.activeParagraphRange(text: text, caretLocation: ns.length + 50)
        #expect(NSMaxRange(activeRange) <= ns.length)
    }

    // MARK: - Markdown-aware active range (issue #127 rules 1.1-1.4)

    @Test("A heading directly above the active paragraph, separated only by blank lines, is pulled into the range")
    func headingDirectlyAboveActiveParagraphIsIncluded() {
        let text = "# Heading\n\nActive paragraph text."
        let ns = text as NSString
        let caretLocation = ns.range(of: "Active").location
        let range = FocusModeEditing.activeDisplayRange(text: text, caretLocation: caretLocation)
        #expect(range.location == 0)
        #expect(ns.substring(with: range) == text)
    }

    @Test("A heading two paragraphs above the caret is never pulled into the active range")
    func headingTwoParagraphsAboveIsNotIncluded() {
        let text = "# Heading\n\nMiddle paragraph.\n\nActive paragraph text."
        let ns = text as NSString
        let caretLocation = ns.range(of: "Active").location
        let range = FocusModeEditing.activeDisplayRange(text: text, caretLocation: caretLocation)
        #expect(ns.substring(with: range) == "Active paragraph text.")
    }

    @Test("A heading immediately above with no blank line separator is already merged by the paragraph rule")
    func headingWithNoBlankLineSeparatorIsAlreadyMerged() {
        let text = "# Heading\nActive paragraph text."
        let ns = text as NSString
        let caretLocation = ns.range(of: "Active").location
        let range = FocusModeEditing.activeDisplayRange(text: text, caretLocation: caretLocation)
        #expect(ns.substring(with: range) == text)
    }

    @Test("Placing the caret on the heading line itself is a no-op -- the heading is already the active range")
    func caretOnHeadingLineItselfIsNoOp() {
        let text = "# Heading\n\nOther paragraph text."
        let ns = text as NSString
        let caretLocation = ns.range(of: "# Heading").location
        let range = FocusModeEditing.activeDisplayRange(text: text, caretLocation: caretLocation)
        #expect(ns.substring(with: range) == "# Heading\n")
    }

    @Test("A non-heading paragraph directly above the active paragraph is not pulled in")
    func nonHeadingParagraphAboveIsNotIncluded() {
        let text = "Plain paragraph.\n\nActive paragraph text."
        let ns = text as NSString
        let caretLocation = ns.range(of: "Active").location
        let range = FocusModeEditing.activeDisplayRange(text: text, caretLocation: caretLocation)
        #expect(ns.substring(with: range) == "Active paragraph text.")
    }

    @Test("lineRange(forCharacterRange:in:) converts a character range to 1-based raw source lines")
    func lineRangeForCharacterRangeConvertsToSourceLines() {
        let text = "# Heading\n\nSecond line of body.\nThird line."
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let lineRange = FocusModeEditing.lineRange(forCharacterRange: range, in: text)
        #expect(lineRange.startLine == 1)
        #expect(lineRange.endLine == 4)
    }

    // MARK: - Coordinator-level dim/undim behavior (rules 3.5, 4.1, 4.3)

    @MainActor
    private func makeAttachedTextView(
        text: String,
        isFocusModeEnabled: Bool,
        isFocusModeDimsTextEnabled: Bool = true,
        isFocusModeCentersCaretEnabled: Bool = true,
        onTextChange: (() -> Void)? = nil,
        onScroll: ((CGFloat) -> Void)? = nil,
        onFocusRangeChange: ((FocusLineRange?) -> Void)? = nil
    ) -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
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
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
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
            isFocusModeEnabled: isFocusModeEnabled,
            isFocusModeDimsTextEnabled: isFocusModeDimsTextEnabled,
            isFocusModeCentersCaretEnabled: isFocusModeCentersCaretEnabled,
            onScroll: onScroll,
            onTextChange: onTextChange,
            onFocusRangeChange: onFocusRangeChange
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        textStorage.highlightDelegate = coordinator

        // Registers the same NSView.boundsDidChangeNotification observer makeNSView sets up in
        // the real app, so recenterCaretOnActiveLine's scroll -- which goes through this exact
        // notification per its doc comment -- reaches scrollViewDidScroll/onScroll in this test too.
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(MarkdownTextView.Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true

        return (textView, coordinator)
    }

    @Test("Disabling focus mode clears every dim attribute it applied")
    @MainActor
    func disablingFocusModeClearsAllDimAttributes() throws {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let (textView, coordinator) = makeAttachedTextView(text: text, isFocusModeEnabled: true)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.applyFocusModeIfNeeded(in: textView)
        let textStorage = try #require(textView.textStorage)
        let dimmedBefore = textStorage.attribute(
            .focusModeOriginalForegroundColor, at: textStorage.length - 1, effectiveRange: nil
        )
        #expect(dimmedBefore != nil, "Expected the third paragraph to be dimmed while focus mode is on")

        coordinator.parent.isFocusModeEnabled = false
        coordinator.applyFocusModeIfNeeded(in: textView)

        for index in 0 ..< textStorage.length {
            #expect(
                textStorage.attribute(.focusModeOriginalForegroundColor, at: index, effectiveRange: nil) == nil,
                "Expected every focus-mode stash attribute to be removed once focus mode turns off"
            )
        }
    }

    @Test("Moving the caret within the same paragraph does not touch other paragraphs' dim state")
    @MainActor
    func caretOnlyMovementAcrossParagraphUpdatesDimWithoutTextChange() throws {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let (textView, coordinator) = makeAttachedTextView(text: text, isFocusModeEnabled: true)
        let ns = text as NSString
        let secondParagraphStart = ns.range(of: "Second").location

        textView.setSelectedRange(NSRange(location: secondParagraphStart, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)

        let textStorage = try #require(textView.textStorage)
        #expect(
            textStorage.attribute(
                .focusModeOriginalForegroundColor, at: secondParagraphStart, effectiveRange: nil
            ) == nil,
            "Expected the active (second) paragraph to be undimmed"
        )
        #expect(
            textStorage.attribute(.focusModeOriginalForegroundColor, at: 0, effectiveRange: nil) != nil,
            "Expected the first paragraph to be dimmed"
        )

        // Move within the same paragraph -- the active range doesn't change, so no attribute
        // work should occur at all (rule 4.1: only boundary changes trigger re-dimming).
        let laterInSecondParagraph = secondParagraphStart + 3
        textView.setSelectedRange(NSRange(location: laterInSecondParagraph, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)

        #expect(
            textStorage.attribute(
                .focusModeOriginalForegroundColor, at: secondParagraphStart, effectiveRange: nil
            ) == nil
        )
    }

    @Test("A keystroke inside the active paragraph never touches the dim state of other paragraphs")
    @MainActor
    func keystrokeOnlyTouchesChangedParagraphRanges() throws {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let (textView, coordinator) = makeAttachedTextView(text: text, isFocusModeEnabled: true)
        let ns = text as NSString
        let secondParagraphStart = ns.range(of: "Second").location
        textView.setSelectedRange(NSRange(location: secondParagraphStart, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)

        let textStorage = try #require(textView.textStorage)
        let firstParagraphColorBefore = try #require(
            textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor
        )
        let thirdParagraphIndex = textStorage.length - 1
        let thirdParagraphColorBefore = try #require(
            textStorage.attribute(.foregroundColor, at: thirdParagraphIndex, effectiveRange: nil) as? PlatformColor
        )

        // Simulate a single keystroke inside the active (second) paragraph -- the only code path
        // `applyFocusModeIfNeeded` ever passes to `dimRange`/`undimRange` is the previously-active
        // and newly-active range, so a same-paragraph edit must leave paragraphs 1 and 3 untouched.
        let insertionPoint = secondParagraphStart + 3
        textStorage.replaceCharacters(in: NSRange(location: insertionPoint, length: 0), with: "!")
        textView.setSelectedRange(NSRange(location: insertionPoint + 1, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)

        let firstParagraphColorAfter = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            as? PlatformColor
        let thirdParagraphColorAfter = textStorage.attribute(
            .foregroundColor, at: thirdParagraphIndex + 1, effectiveRange: nil
        ) as? PlatformColor
        #expect(firstParagraphColorAfter == firstParagraphColorBefore, "First paragraph's dim must be untouched")
        #expect(thirdParagraphColorAfter == thirdParagraphColorBefore, "Third paragraph's dim must be untouched")
        #expect(
            textStorage.attribute(.focusModeOriginalForegroundColor, at: insertionPoint, effectiveRange: nil) == nil,
            "The newly typed character in the active paragraph must not be dimmed"
        )
    }

    @Test("The dim attribute composes with Highlightr's syntax-highlighting color instead of replacing it")
    @MainActor
    func dimAttributeComposesWithSyntaxHighlightingAttributes() throws {
        // The heading sits two paragraphs above the caret (issue #127 rule 1.2 only pulls in a
        // heading directly above the active paragraph), so it stays dimmed here.
        let text = "# Heading\n\nMiddle paragraph.\n\nplain paragraph text"
        let (textView, coordinator) = makeAttachedTextView(text: text, isFocusModeEnabled: true)
        let ns = text as NSString
        let plainParagraphStart = ns.range(of: "plain").location

        // Give Highlightr's async highlight pass time to land before asserting on its output.
        textView.setSelectedRange(NSRange(location: plainParagraphStart, length: 0))
        var attempts = 0
        while textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil, attempts < 50 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            attempts += 1
        }

        coordinator.applyFocusModeIfNeeded(in: textView)
        let textStorage = try #require(textView.textStorage)

        // The heading (dimmed, since it's not the active paragraph) must still carry a
        // .foregroundColor attribute (Highlightr's), not have lost it to the dim pass.
        let headingColor = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(headingColor != nil, "Expected the dimmed heading to still carry a foreground color attribute")
        let stash = textStorage.attribute(.focusModeOriginalForegroundColor, at: 0, effectiveRange: nil)
        #expect(stash != nil, "Expected the dimmed heading's original color to be stashed for later restoration")
    }

    @Test("Re-dimming after Highlightr's async highlight lands only touches the overlap with dimmed ranges")
    @MainActor
    func didHighlightOnlyRedimsOverlapWithDimmedRanges() throws {
        let text = "First paragraph.\n\nSecond paragraph."
        let (textView, coordinator) = makeAttachedTextView(text: text, isFocusModeEnabled: true)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)

        let textStorage = try #require(textView.textStorage)
        let ns = text as NSString
        let secondParagraphRange = ns.range(of: "Second paragraph.")

        // Simulate Highlightr re-highlighting (and thus wiping any dim within) the whole
        // document, as its `setAttributes` call does after an async pass completes.
        textStorage.beginEditing()
        textStorage.removeAttribute(.focusModeOriginalForegroundColor, range: NSRange(location: 0, length: ns.length))
        textStorage.addAttribute(
            .foregroundColor,
            value: PlatformColor.textColor,
            range: NSRange(location: 0, length: ns.length)
        )
        textStorage.endEditing()

        coordinator.didHighlight(NSRange(location: 0, length: ns.length), success: true)

        // The active (first) paragraph must remain undimmed; the second (dimmed) paragraph
        // must have its dim restored by didHighlight.
        #expect(textStorage.attribute(.focusModeOriginalForegroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(
            textStorage.attribute(
                .focusModeOriginalForegroundColor, at: secondParagraphRange.location, effectiveRange: nil
            ) != nil,
            "Expected didHighlight to re-dim the second paragraph after Highlightr's setAttributes wiped it"
        )
    }

    // MARK: - Independent dim/center preferences (issue #127 rules 2.1-2.3)

    @Test("Toggling isFocusModeDimsTextEnabled off with the caret unchanged clears dimming immediately")
    @MainActor
    func togglingDimsTextEnabledOffWithUnchangedCaretClearsDimming() throws {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let (textView, coordinator) = makeAttachedTextView(text: text, isFocusModeEnabled: true)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)

        let textStorage = try #require(textView.textStorage)
        #expect(
            textStorage.attribute(.focusModeOriginalForegroundColor, at: textStorage.length - 1, effectiveRange: nil)
                != nil,
            "Expected the third paragraph to be dimmed while dimming is enabled"
        )

        coordinator.parent.isFocusModeDimsTextEnabled = false
        coordinator.applyFocusModeIfNeeded(in: textView)

        for index in 0 ..< textStorage.length {
            #expect(
                textStorage.attribute(.focusModeOriginalForegroundColor, at: index, effectiveRange: nil) == nil,
                "Expected dimming to clear immediately once the dims-text preference turns off"
            )
        }
    }

    @Test("Toggling isFocusModeDimsTextEnabled back on with the caret unchanged re-dims the document")
    @MainActor
    func togglingDimsTextEnabledOnWithUnchangedCaretReDims() throws {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let (textView, coordinator) = makeAttachedTextView(
            text: text, isFocusModeEnabled: true, isFocusModeDimsTextEnabled: false
        )
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)

        let textStorage = try #require(textView.textStorage)
        #expect(textStorage.attribute(
            .focusModeOriginalForegroundColor,
            at: textStorage.length - 1,
            effectiveRange: nil
        ) == nil)

        coordinator.parent.isFocusModeDimsTextEnabled = true
        coordinator.applyFocusModeIfNeeded(in: textView)

        #expect(
            textStorage.attribute(.focusModeOriginalForegroundColor, at: textStorage.length - 1, effectiveRange: nil)
                != nil,
            "Expected the third paragraph to become dimmed once isFocusModeDimsTextEnabled turns on"
        )
    }

    @Test("recenterCaretOnActiveLine is a no-op when isFocusModeCentersCaretEnabled is off")
    @MainActor
    func recenteringNoOpWhenCentersCaretDisabled() throws {
        let text = Array(repeating: "Paragraph.", count: 200).joined(separator: "\n\n")
        let (textView, coordinator) = makeAttachedTextView(
            text: text, isFocusModeEnabled: true, isFocusModeCentersCaretEnabled: false
        )
        let scrollView = try #require(textView.enclosingScrollView)
        let originBefore = scrollView.contentView.bounds.origin
        let ns = text as NSString
        textView.setSelectedRange(NSRange(location: ns.length - 1, length: 0))

        coordinator.recenterCaretOnActiveLine(in: textView)

        #expect(
            scrollView.contentView.bounds.origin == originBefore,
            "Expected no scroll when centering is disabled independent of dimming (issue #127 rule 2.3)"
        )
    }

    // MARK: - onFocusRangeChange notification (issue #127 rules 3.3, 4.2)

    @Test("onFocusRangeChange fires with the active range's source lines when focus mode is enabled")
    @MainActor
    func onFocusRangeChangeFiresWithActiveLineRange() throws {
        let text = "First paragraph.\n\nSecond paragraph."
        var receivedValues: [FocusLineRange?] = []
        let ns = text as NSString
        let secondParagraphStart = ns.range(of: "Second").location
        let (textView, coordinator) = makeAttachedTextView(
            text: text,
            isFocusModeEnabled: true,
            onFocusRangeChange: { receivedValues.append($0) }
        )
        textView.setSelectedRange(NSRange(location: secondParagraphStart, length: 0))

        coordinator.applyFocusModeIfNeeded(in: textView)

        let lastValue = try #require(receivedValues.last)
        let expected = try #require(lastValue)
        #expect(expected.startLine == 3)
        #expect(expected.endLine == 3)
    }

    @Test("onFocusRangeChange does not fire again when the display range hasn't changed")
    @MainActor
    func onFocusRangeChangeDoesNotFireRedundantly() {
        let text = "First paragraph.\n\nSecond paragraph."
        var callCount = 0
        let ns = text as NSString
        let secondParagraphStart = ns.range(of: "Second").location
        let (textView, coordinator) = makeAttachedTextView(
            text: text,
            isFocusModeEnabled: true,
            onFocusRangeChange: { _ in callCount += 1 }
        )
        textView.setSelectedRange(NSRange(location: secondParagraphStart, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)
        #expect(callCount == 1)

        // Move within the same paragraph -- the active range doesn't change, so the callback
        // must not fire again.
        textView.setSelectedRange(NSRange(location: secondParagraphStart + 3, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)
        #expect(callCount == 1, "Expected no redundant notification when the active range is unchanged")
    }

    @Test("onFocusRangeChange fires nil when focus mode is disabled")
    @MainActor
    func onFocusRangeChangeFiresNilWhenDisabled() throws {
        let text = "First paragraph.\n\nSecond paragraph."
        var receivedValues: [FocusLineRange?] = []
        let (textView, coordinator) = makeAttachedTextView(
            text: text,
            isFocusModeEnabled: true,
            onFocusRangeChange: { receivedValues.append($0) }
        )
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyFocusModeIfNeeded(in: textView)
        #expect(receivedValues.last != nil)

        coordinator.parent.isFocusModeEnabled = false
        coordinator.applyFocusModeIfNeeded(in: textView)

        let lastValue = try #require(receivedValues.last)
        #expect(lastValue == nil, "Expected a nil notification once focus mode turns off")
    }

    @Test("onFocusRangeChange fires nil when dimming is disabled even though focus mode is on")
    @MainActor
    func onFocusRangeChangeFiresNilWhenDimmingDisabled() throws {
        let text = "First paragraph.\n\nSecond paragraph."
        var receivedValues: [FocusLineRange?] = []
        let (textView, coordinator) = makeAttachedTextView(
            text: text,
            isFocusModeEnabled: true,
            isFocusModeDimsTextEnabled: false,
            onFocusRangeChange: { receivedValues.append($0) }
        )
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.applyFocusModeIfNeeded(in: textView)

        let lastValue = try #require(receivedValues.last)
        #expect(lastValue == nil, "Expected nil when the dim preference is off (issue #127 rule 3.4)")
    }

    // MARK: - Typewriter recentering (rules 4.4, 4.5)

    @Test("Typewriter recentering computes a scroll offset that centers the caret's line, clamped to bounds")
    func typewriterRecenteringReusesExistingScrollSyncPath() {
        // caretLineTop far below the viewport: offset should center it, not clamp to 0.
        let offset = FocusModeEditing.centeringOffset(caretLineTop: 1000, visibleHeight: 400)
        #expect(offset == 800)

        // caretLineTop near the top: offset clamps to 0 rather than going negative.
        let clampedOffset = FocusModeEditing.centeringOffset(caretLineTop: 10, visibleHeight: 400)
        #expect(clampedOffset == 0)
    }

    @Test("Recentering on a document that fits entirely within the viewport is a no-op")
    @MainActor
    func recenteringNoOpWhenDocumentFitsViewport() throws {
        let text = "Short document."
        let (textView, coordinator) = makeAttachedTextView(text: text, isFocusModeEnabled: true)
        let scrollView = try #require(textView.enclosingScrollView)
        let originBefore = scrollView.contentView.bounds.origin

        coordinator.recenterCaretOnActiveLine(in: textView)

        #expect(scrollView.contentView.bounds.origin == originBefore)
    }

    @Test("Recentering scrolls only the editor's own scroll position, reusing the onScroll/ScrollSync path")
    @MainActor
    func typewriterRecenteringDoesNotTriggerFullRender() {
        // `MarkdownTextView.Coordinator` (Shared/Editor/MarkdownTextView.swift) stores only
        // `parent`/`textView`/scroll-anchor/focus-mode state -- no reference to `SplitEditorView`,
        // `scheduleRender`, or `renderMarkdown` exists to call, so "never forces a full re-render"
        // (rule 4.4) is structurally true, not just unexercised by this test.
        let text = Array(repeating: "Paragraph.", count: 200).joined(separator: "\n\n")
        var capturedFraction: CGFloat?
        let (textView, coordinator) = makeAttachedTextView(
            text: text,
            isFocusModeEnabled: true,
            onScroll: { capturedFraction = $0 }
        )
        let ns = text as NSString
        // `lineTop(forCharacterIndex:)` requires an in-bounds index (it returns nil at
        // `ns.length` itself, the trailing empty position after the last character).
        textView.setSelectedRange(NSRange(location: ns.length - 1, length: 0))

        coordinator.recenterCaretOnActiveLine(in: textView)

        #expect(capturedFraction != nil, "Expected recentering's scroll to be forwarded through onScroll")
    }
}
