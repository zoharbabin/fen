import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Harness gate 3 for issue #19, rule 1.1: two `MarkdownTextView.Coordinator` instances never
/// share or leak focus-mode dim/active-range state -- mirrors `PreviewAppearanceIsolationTests.swift`'s
/// two-instance pattern.
struct FocusModeIsolationTests {
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
            isFocusModeEnabled: true
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        textStorage.highlightDelegate = coordinator
        return (textView, coordinator)
    }

    @Test @MainActor
    func twoCoordinatorInstancesDoNotShareDimState() throws {
        let textA = "First paragraph A.\n\nSecond paragraph A."
        let textB = "First paragraph B.\n\nSecond paragraph B."
        let (textViewA, coordinatorA) = makeAttachedTextView(text: textA)
        let (textViewB, coordinatorB) = makeAttachedTextView(text: textB)

        textViewA.setSelectedRange(NSRange(location: 0, length: 0))
        coordinatorA.applyFocusModeIfNeeded(in: textViewA)

        // Coordinator B never had applyFocusModeIfNeeded called, so it must have no active
        // range at all -- proves the two instances' focusModeActiveRange fields are distinct
        // storage, not a shared/static default.
        #expect(coordinatorA.focusModeActiveRange != nil)
        #expect(coordinatorB.focusModeActiveRange == nil)

        let storageB = try #require(textViewB.textStorage)
        for index in 0 ..< storageB.length {
            #expect(
                storageB.attribute(.focusModeOriginalForegroundColor, at: index, effectiveRange: nil) == nil,
                "Dimming coordinator A's text view must never touch coordinator B's text storage"
            )
        }
    }

    @Test @MainActor
    func twoInstancesOverSameDocumentTextStayIndependent() throws {
        let sharedText = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let (textViewA, coordinatorA) = makeAttachedTextView(text: sharedText)
        let (textViewB, coordinatorB) = makeAttachedTextView(text: sharedText)

        let ns = sharedText as NSString
        let secondParagraphStart = ns.range(of: "Second").location
        let thirdParagraphStart = ns.range(of: "Third").location

        textViewA.setSelectedRange(NSRange(location: 0, length: 0))
        coordinatorA.applyFocusModeIfNeeded(in: textViewA)

        textViewB.setSelectedRange(NSRange(location: thirdParagraphStart, length: 0))
        coordinatorB.applyFocusModeIfNeeded(in: textViewB)

        // Even though both coordinators started from identical document text, each computed
        // its own active range from its own text view's caret -- never a shared/cached value.
        let rangeA = try #require(coordinatorA.focusModeActiveRange)
        let rangeB = try #require(coordinatorB.focusModeActiveRange)
        #expect(rangeA.location == 0)
        #expect(rangeB.location == thirdParagraphStart)

        let storageA = try #require(textViewA.textStorage)
        let storageB = try #require(textViewB.textStorage)
        // A's active (first) paragraph is undimmed; B dimmed its own first paragraph instead.
        #expect(storageA.attribute(.focusModeOriginalForegroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(storageB.attribute(.focusModeOriginalForegroundColor, at: 0, effectiveRange: nil) != nil)
        // B's active (third) paragraph is undimmed in B; the same range in A's text is dimmed.
        #expect(storageB
            .attribute(.focusModeOriginalForegroundColor, at: thirdParagraphStart, effectiveRange: nil) == nil)
        #expect(storageA
            .attribute(.focusModeOriginalForegroundColor, at: secondParagraphStart, effectiveRange: nil) != nil)
    }
}
