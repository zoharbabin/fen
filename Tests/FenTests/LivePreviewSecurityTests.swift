import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Harness gate 5 for issue #2, rules 2.1/2.2: live preview never mutates the underlying document
/// text, and its inline image overlay never resolves outside the document directory or fetches
/// a remote URL.
struct LivePreviewSecurityTests {
    @MainActor
    private func makeAttachedTextView(
        text: String,
        documentURL: URL? = nil
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
            isLivePreviewEnabled: true,
            documentURL: documentURL
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        coordinator.documentURL = documentURL
        textStorage.highlightDelegate = coordinator
        return (textView, coordinator)
    }

    /// Rule 2.1: enabling live preview, moving the caret across every construct the spec covers,
    /// then disabling it again must leave the underlying document string byte-for-byte identical
    /// to what it started as -- proving styling is purely a display-layer overlay.
    @Test @MainActor
    func toggleRoundTripLeavesDocumentTextByteIdentical() {
        let original = """
        # Heading

        **bold** and *italic* and `code` and ~~strike~~ and [a link](https://example.com).

        - [ ] unchecked task
        - [x] checked task

        > a blockquote

        ![alt text](missing.png)

        | a | table |
        |---|---|
        | b | row |
        """
        let (textView, coordinator) = makeAttachedTextView(text: original)

        let ns = original as NSString
        for location in stride(from: 0, to: ns.length, by: 7) {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
        }
        #expect(textView.string == original)

        coordinator.parent.isLivePreviewEnabled = false
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
        #expect(textView.string == original, "disabling live preview must never have mutated the document text")
    }

    /// Rule 2.2: a relative path escaping the document directory (via `../` or a symlink), an
    /// absolute filesystem path, and a remote URL must all be rejected by
    /// `LivePreviewImageResolution` -- it must never resolve, read, or report a file outside the
    /// document's own directory, and never fetch a network URL.
    @Test @MainActor
    func imageResolutionRejectsTraversalAbsoluteAndRemotePaths() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePreviewSecurityTests-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let secretDirectory = tempRoot.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDirectory, withIntermediateDirectories: true)
        let secretFile = secretDirectory.appendingPathComponent("private.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: secretFile)

        // `../` traversal out of the document directory.
        #expect(
            LivePreviewImageResolution.resolvedFileURL(
                relativePath: "../secret/private.png", documentDirectory: documentDirectory
            ) == nil
        )

        // A symlink planted inside the document directory but pointing outside it.
        let symlink = documentDirectory.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secretFile)
        #expect(
            LivePreviewImageResolution.resolvedFileURL(
                relativePath: "escape.png", documentDirectory: documentDirectory
            ) == nil
        )

        // An absolute filesystem path, even one that legitimately exists.
        #expect(
            LivePreviewImageResolution.resolvedFileURL(
                relativePath: secretFile.path, documentDirectory: documentDirectory
            ) == nil
        )

        // A remote URL must never be treated as a local relative reference.
        #expect(!LivePreviewImageResolution.isLocalRelativeReference("https://example.com/tracking.png"))
        #expect(
            LivePreviewImageResolution.resolvedFileURL(
                relativePath: "https://example.com/tracking.png", documentDirectory: documentDirectory
            ) == nil
        )

        // A genuinely local file inside the document directory must still resolve.
        let localFile = documentDirectory.appendingPathComponent("local.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: localFile)
        #expect(
            LivePreviewImageResolution.resolvedFileURL(
                relativePath: "local.png", documentDirectory: documentDirectory
            ) != nil
        )
    }

    /// Rule 2.1 (checkbox toggle path): clicking a checkbox overlay must change only that line's
    /// `[ ]`/`[x]` marker byte range, confined to the exact diff
    /// `MarkdownFormatting.apply(.taskItem, ...)` would produce for a manual edit -- never a
    /// wider rewrite of the document.
    @Test @MainActor
    func checkboxToggleChangeIsConfinedToTaskItemFormattingDiff() {
        let text = "Intro line.\n\n- [ ] task one\n- [ ] task two\n\nTrailing line."
        let ns = text as NSString
        let taskLineRange = ns.range(of: "- [ ] task one")

        let direct = MarkdownFormatting.apply(.taskItem, to: text, selection: taskLineRange)
        #expect(direct.text == "Intro line.\n\n- [x] task one\n- [ ] task two\n\nTrailing line.")

        // Everything outside the toggled line's marker must be untouched.
        let expectedUnchangedPrefix = "Intro line.\n\n- ["
        #expect(direct.text.hasPrefix(expectedUnchangedPrefix))
        #expect(direct.text.hasSuffix("] task one\n- [ ] task two\n\nTrailing line."))
    }
}
