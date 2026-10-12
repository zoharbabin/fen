import AppKit
@testable import FenCore
import Foundation
import Testing

/// Issue #42: the Format commands post a notification that every open editor hears. Only the editor
/// in the key window may change, or Bold in one document would edit all the others too.
struct FormattingTargetsKeyWindowTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool {
            true
        }
    }

    @MainActor
    private func makeEditor(in window: NSWindow, text: String) -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        window.contentView = textView

        let parent = MarkdownTextView(
            text: .constant(text),
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            highlightThemeName: "xcode",
            lineSpacing: 0,
            horizontalInset: 0,
            verticalInset: 0,
            isEditable: true,
            scrollsPastEnd: false
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        return (textView, coordinator)
    }

    private func window(_ type: NSWindow.Type) -> NSWindow {
        type.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    @Test @MainActor
    func boldChangesTheKeyWindowsDocumentAndNoOtherOne() {
        let (front, frontCoordinator) = makeEditor(in: window(KeyWindow.self), text: "front")
        let (back, backCoordinator) = makeEditor(in: window(NSWindow.self), text: "back")
        front.setSelectedRange(NSRange(location: 0, length: 5))
        back.setSelectedRange(NSRange(location: 0, length: 4))

        let note = Notification(name: .insertMarkdownFormatting, object: FormattingAction.bold.identifier)
        frontCoordinator.applyFormattingNotification(note)
        backCoordinator.applyFormattingNotification(note)

        #expect(front.string == "**front**")
        #expect(back.string == "back")
    }
}
