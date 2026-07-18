import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing
import UniformTypeIdentifiers

/// End-to-end test for issue #18, rule 5.3: a real `MarkdownNSTextView` receiving a real image
/// paste through `NSPasteboard`, exercising the actual `readSelection(from:type:)` override
/// production code takes -- not a call directly into `ImageSidecarWriter`/`MarkdownFormatting`
/// (that's already covered by `ImagePasteInsertionTests`). Mirrors
/// `EditorFontSizeScrollSyncVerifyTest`'s real-`NSTextView`-in-a-real-window construction.
@Suite("Pasting an image into the editor writes a sidecar file and inserts a Markdown link")
struct ImagePasteE2ETest {
    @MainActor
    private func makeAttachedTextView(documentURL: URL?) -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let textStorage = CodeAttributedString()
        textStorage.language = "markdown"
        textStorage.highlightr.setTheme(to: "xcode")

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)

        let textView = MarkdownNSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.font = font
        textView.string = ""

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView

        let parent = MarkdownTextView(
            text: .constant(""),
            font: font,
            highlightThemeName: "xcode",
            lineSpacing: 0,
            horizontalInset: 0,
            verticalInset: 0,
            isEditable: true,
            scrollsPastEnd: false,
            documentURL: documentURL
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        coordinator.documentURL = documentURL
        textView.imagePasteCoordinator = coordinator
        return (textView, coordinator)
    }

    /// A minimal but real, valid single-pixel PNG -- not placeholder bytes -- so this exercises
    /// the same `.png` pasteboard type a real screenshot/copy would offer.
    private var onePixelPNG: Data {
        Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
    }

    @Test("Pasting a real PNG into a saved document writes the sidecar file and inserts its link")
    @MainActor
    func pastingImageIntoSavedDocumentWritesFileAndInsertsLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagePasteE2ETest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")

        // `imagePasteCoordinator` is `weak` (see MarkdownTextView.swift) -- must keep a strong
        // reference to `coordinator` for the duration of this test, or it's deallocated before
        // `readSelection` runs and the paste silently falls through to AppKit's own default
        // image-attachment embedding instead of this feature's code path.
        let (textView, coordinator) = makeAttachedTextView(documentURL: documentURL)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ImagePasteE2ETest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(onePixelPNG, forType: .png)

        let handled = textView.readSelection(from: pasteboard, type: .png)

        withExtendedLifetime(coordinator) {
            #expect(handled)
            #expect(textView.string == "![image-1.png](notes.assets/image-1.png)")
        }
        let writtenFile = directory.appendingPathComponent("notes.assets/image-1.png")
        #expect(FileManager.default.fileExists(atPath: writtenFile.path))
        #expect(try Data(contentsOf: writtenFile) == onePixelPNG)
    }

    @Test("Pasting into an unsaved document declines without writing a file or hanging on an alert")
    @MainActor
    func pastingImageIntoUnsavedDocumentDeclinesCleanly() {
        let (textView, coordinator) = makeAttachedTextView(documentURL: nil)
        var alertPresented = false
        coordinator.presentUnsavedDocumentAlert = { alertPresented = true }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ImagePasteE2ETest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(onePixelPNG, forType: .png)

        _ = textView.readSelection(from: pasteboard, type: .png)

        #expect(alertPresented)
        #expect(!textView.string.contains("](notes.assets/"))
    }
}
