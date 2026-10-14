import AppKit
@testable import FenCore
import Highlightr

/// A text view in Live Preview with a `DecorationLayoutManager`, in a window, wired to a coordinator.
@MainActor
func makeLivePreviewView(
    _ text: String, background: NSColor = .white, width: CGFloat = 400
) -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
    let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let storage = CodeAttributedString()
    storage.language = "markdown"
    storage.highlightr.setTheme(to: "xcode")
    let layoutManager = DecorationLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    layoutManager.addTextContainer(container)
    let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 300), textContainer: container)
    textView.isEditable = true
    textView.isRichText = true
    textView.font = font
    textView.appearance = NSAppearance(named: .aqua)
    textView.drawsBackground = true
    textView.backgroundColor = background
    textView.string = text
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = textView
    let parent = MarkdownTextView(
        text: .constant(text),
        font: font,
        highlightThemeName: "xcode",
        lineSpacing: 0,
        horizontalInset: 0,
        verticalInset: 0,
        isEditable: true,
        scrollsPastEnd: false,
        isLivePreviewEnabled: true,
        documentURL: nil
    )
    let coordinator = parent.makeCoordinator()
    coordinator.textView = textView
    storage.highlightDelegate = coordinator
    return (textView, coordinator)
}
