import AppKit
@testable import FenCore
import Foundation
import Highlightr
import SwiftUI
import Testing

/// Drives a real `MarkdownNSTextView` in a real window for issue #8: the editor reports what you
/// select and write, and applies "Insert Link" through the undo stack.
@Suite("Related documents in the real editor (issue #8)", .serialized)
@MainActor
struct RelatedEditorE2ETests {
    private final class Box {
        var text = ""
        var reports: [EditorSelection?] = []
    }

    private func makeEditor(
        _ box: Box,
        insertion: EditorInsertion? = nil
    ) -> (MarkdownNSTextView, MarkdownTextView.Coordinator, NSWindow) {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let textStorage = CodeAttributedString()
        textStorage.language = "markdown"
        textStorage.highlightr.setTheme(to: "xcode")
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = font
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        let parent = MarkdownTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            font: font, highlightThemeName: "xcode", lineSpacing: 0, horizontalInset: 0, verticalInset: 0,
            isEditable: true, scrollsPastEnd: false,
            onSelectionChange: { box.reports.append($0) }, insertion: insertion
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        textView.delegate = coordinator
        return (textView, coordinator, window)
    }

    @Test("selecting text reports it, and a caret reports nothing until you have typed")
    func reportsSelection() {
        let box = Box()
        let (textView, _, window) = makeEditor(box)
        withExtendedLifetime(window) {
            let text = "Alpha beta gamma delta epsilon.\n\nSecond paragraph of the page."
            textView.string = text
            textView.setSelectedRange((text as NSString).range(of: "beta gamma delta"))
            #expect(box.reports.last??.kind == .selection)
            #expect(box.reports.last??.text == "beta gamma delta")
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            #expect(box.reports.last! == nil)
        }
    }

    @Test("typing reports the paragraph you are writing")
    func reportsParagraphWhileTyping() {
        let box = Box()
        let (textView, _, window) = makeEditor(box)
        withExtendedLifetime(window) {
            window.makeFirstResponder(textView)
            textView.insertText(
                "We release and deploy the signed archive every single week.",
                replacementRange: NSRange(location: 0, length: 0)
            )
            let last = box.reports.compactMap(\.self).last
            #expect(last?.kind == .paragraph)
            #expect(last?.text == "We release and deploy the signed archive every single week.")
        }
    }

    @Test("an insertion lands once, updates the binding, and Undo takes it back")
    func insertionIsUndoable() throws {
        let box = Box()
        let (textView, coordinator, window) = makeEditor(box)
        try withExtendedLifetime(window) {
            window.makeFirstResponder(textView)
            let original = "See release and deploy the signed archive for details."
            textView.string = original
            box.text = original
            let range = (original as NSString).range(of: "release and deploy the signed archive")
            let edit = EditorInsertion(
                range: range,
                expected: "release and deploy the signed archive",
                text: "[release and deploy the signed archive](ship.md)"
            )
            coordinator.apply(edit, to: textView)
            let linked = "See [release and deploy the signed archive](ship.md) for details."
            #expect(textView.string == linked)
            #expect(box.text == linked)
            coordinator.apply(edit, to: textView)
            #expect(textView.string == linked)
            let undo = try #require(textView.undoManager)
            undo.undo()
            #expect(textView.string == original)
        }
    }

    @Test("an insertion is skipped when the text under it changed")
    func staleInsertionIsSkipped() {
        let box = Box()
        let (textView, coordinator, window) = makeEditor(box)
        withExtendedLifetime(window) {
            textView.string = "Totally different text now"
            let edit = EditorInsertion(range: NSRange(location: 4, length: 5), expected: "brave", text: "X")
            coordinator.apply(edit, to: textView)
            #expect(textView.string == "Totally different text now")
        }
    }
}
