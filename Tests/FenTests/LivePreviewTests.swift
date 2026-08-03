import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Harness gate 5 for issue #2, rules 3.1/3.2/4.1/4.3/5.3: functional behavior of the live-preview
/// styling pass beyond pure isolation/security concerns.
struct LivePreviewTests {
    /// A minimal, valid 1x1 PNG -- small enough to inline, real enough for `NSImage` to decode.
    private static let onePixelPNGData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54,
        0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
        0x0D, 0x0A, 0x2D, 0xB4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    @MainActor
    private func makeAttachedTextView(
        text: String, documentURL: URL? = nil
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

    /// Rule 3.1: an image reference whose file doesn't exist must leave its raw `![alt](path)`
    /// syntax fully visible -- never hidden with nothing shown in its place. Regression coverage
    /// for the marker-hidden-before-load-succeeded bug found and fixed while writing this test.
    @Test @MainActor
    func imageAttachmentFallsBackToRawSyntaxOnLoadFailure() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let documentURL = tempRoot.appendingPathComponent("doc.md")

        let text = "Intro paragraph.\n\n![missing](missing.png)"
        let (textView, coordinator) = makeAttachedTextView(text: text, documentURL: documentURL)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)

        #expect(textView.string == text, "A failed image load must never mutate the document text")
        let textStorage = try #require(textView.textStorage)
        let ns = text as NSString
        let imageLineStart = ns.range(of: "![missing]").location
        #expect(
            textStorage.attribute(.livePreviewTouched, at: imageLineStart, effectiveRange: nil) == nil,
            "The raw ![alt](path) syntax must stay fully visible, not be hidden, when the image fails to load"
        )
    }

    /// Rule 3.2 (paired with 3.1): a resolvable, decodable local image is hidden behind its
    /// overlay -- proving the fallback path in the test above is specific to load failure, not
    /// a styling pass that never touches images at all.
    @Test @MainActor
    func imageAttachmentIsHiddenBehindOverlayOnLoadSuccess() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let documentURL = tempRoot.appendingPathComponent("doc.md")
        try Self.onePixelPNGData.write(to: tempRoot.appendingPathComponent("pic.png"))

        let text = "Intro paragraph.\n\n![a pixel](pic.png)"
        let (textView, coordinator) = makeAttachedTextView(text: text, documentURL: documentURL)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)

        #expect(textView.string == text)
        let textStorage = try #require(textView.textStorage)
        let ns = text as NSString
        let imageLineStart = ns.range(of: "![a pixel]").location
        #expect(
            textStorage.attribute(.livePreviewTouched, at: imageLineStart, effectiveRange: nil) != nil,
            "A successfully loaded image's raw syntax must be hidden behind its overlay"
        )
    }

    /// Rule 4.1: a keystroke inside the active paragraph must never touch styling attributes on
    /// paragraphs it didn't overlap -- only the previous and new active ranges get restyled.
    @Test @MainActor
    func stylingPassIsScopedToEditedParagraphNotWholeDocument() throws {
        let text = "**First bold** paragraph.\n\n**Second bold** paragraph.\n\n**Third bold** paragraph."
        let (textView, coordinator) = makeAttachedTextView(text: text)
        let ns = text as NSString
        let secondParagraphStart = ns.range(of: "**Second").location
        let thirdParagraphStart = ns.range(of: "**Third").location

        textView.setSelectedRange(NSRange(location: secondParagraphStart, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)

        let textStorage = try #require(textView.textStorage)
        let thirdParagraphFontBefore = try #require(
            textStorage.attribute(.font, at: thirdParagraphStart, effectiveRange: nil) as? NSFont
        )

        // Type inside the second (active) paragraph -- the third paragraph's already-applied
        // bold styling must be completely untouched by this pass.
        let insertionPoint = secondParagraphStart + 3
        textStorage.replaceCharacters(in: NSRange(location: insertionPoint, length: 0), with: "!")
        textView.setSelectedRange(NSRange(location: insertionPoint + 1, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)

        let thirdParagraphFontAfter = textStorage.attribute(
            .font, at: thirdParagraphStart + 1, effectiveRange: nil
        ) as? NSFont
        #expect(thirdParagraphFontAfter == thirdParagraphFontBefore, "Untouched paragraph's styling must be stable")
    }

    /// Rule 4.3: an image already decoded once must be served from `livePreviewImageCache` on a
    /// repeated styling pass, not re-read/re-decoded from disk.
    @Test @MainActor
    func imageAttachmentIsCachedNotReDecodedOnRepeatedStyling() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let documentURL = tempRoot.appendingPathComponent("doc.md")
        let imageFile = tempRoot.appendingPathComponent("pic.png")
        try Self.onePixelPNGData.write(to: imageFile)

        let text = "Intro paragraph.\n\n![a pixel](pic.png)"
        let (textView, coordinator) = makeAttachedTextView(text: text, documentURL: documentURL)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)
        #expect(coordinator.livePreviewImageCache[imageFile.path] != nil, "Expected the decoded image to be cached")

        // Delete the file from disk -- if a second styling pass re-read it instead of using the
        // cache, the image would now fail to load.
        try FileManager.default.removeItem(at: imageFile)

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)

        let textStorage = try #require(textView.textStorage)
        let ns = text as NSString
        let imageLineStart = ns.range(of: "![a pixel]").location
        #expect(
            textStorage.attribute(.livePreviewTouched, at: imageLineStart, effectiveRange: nil) != nil,
            "Expected the cached image to still render as hidden-behind-overlay after the file was deleted"
        )
    }

    /// Rule 5.3: any line containing a table pipe (`|`) is left completely unstyled by design --
    /// live preview doesn't attempt to render tables, so it must not touch their raw syntax.
    @Test @MainActor
    func tableSyntaxIsLeftUnstyled() throws {
        let text = "Intro.\n\n| a | table |\n|---|---|\n| **bold** | *italic* |"
        let (textView, coordinator) = makeAttachedTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)

        #expect(textView.string == text)
        let textStorage = try #require(textView.textStorage)
        let ns = text as NSString
        for marker in ["a", "table", "---", "bold", "italic"] {
            let location = ns.range(of: marker).location
            #expect(
                textStorage.attribute(.livePreviewTouched, at: location, effectiveRange: nil) == nil,
                "Expected table row content '\(marker)' to be left completely unstyled"
            )
        }
    }

    /// Rule 2.1--2.3 (issue #128): a fenced code block's content and delimiter lines are left
    /// completely unstyled, mirroring `tableSyntaxIsLeftUnstyled`'s exact assertion pattern --
    /// code content like Python's `**kwargs` or a shell `` `cmd` `` must never be misread as
    /// Markdown emphasis/code-span syntax.
    @Test @MainActor
    func fencedCodeBlockSyntaxIsLeftUnstyled() throws {
        let text = "Intro.\n\n```python\ndef f(**kwargs):\n    return `not code marker` * 2\n```\n\nOutro."
        let (textView, coordinator) = makeAttachedTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)

        #expect(textView.string == text)
        let textStorage = try #require(textView.textStorage)
        let ns = text as NSString
        for marker in ["```python", "kwargs", "not code marker", "```\n\nOutro"] {
            let location = ns.range(of: marker).location
            #expect(
                location != NSNotFound,
                "Expected to find '\(marker)' in the test fixture"
            )
            #expect(
                textStorage.attribute(.livePreviewTouched, at: location, effectiveRange: nil) == nil,
                "Expected fenced code block content '\(marker)' to be left completely unstyled"
            )
        }
    }

    /// Rule 2.1: an unterminated trailing fence (no closing delimiter before EOF) still suppresses
    /// styling all the way to the document's end, rather than being ignored because it never closes.
    @Test @MainActor
    func unterminatedFenceSuppressesStylingToEndOfDocument() throws {
        let text = "Intro.\n\n```\ndef f(**kwargs):\n    pass"
        let (textView, coordinator) = makeAttachedTextView(text: text)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: false)

        let textStorage = try #require(textView.textStorage)
        let ns = text as NSString
        let location = ns.range(of: "kwargs").location
        #expect(
            textStorage.attribute(.livePreviewTouched, at: location, effectiveRange: nil) == nil,
            "Expected content after an unterminated fence to remain unstyled"
        )
    }
}
