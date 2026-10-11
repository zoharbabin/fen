import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing

/// Issue #135, phase 1: horizontal rules, lists and footnotes in Live Preview.
struct LivePreviewBlockDetectionTests {
    @Test func ruleForms() {
        for line in ["---", "***", "___", "- - -", "* * *", "  ---", "-----"] {
            #expect(LivePreviewEditing.isHorizontalRule(line: line, previousLine: ""), "\(line)")
        }
    }

    @Test func notRules() {
        for line in ["--", "    ---", "-*-", "--- x", "text"] {
            #expect(!LivePreviewEditing.isHorizontalRule(line: line, previousLine: ""), "\(line)")
        }
    }

    @Test func dashesUnderTextAreASetextUnderlineNotARule() {
        #expect(!LivePreviewEditing.isHorizontalRule(line: "---", previousLine: "Title"))
        #expect(LivePreviewEditing.isHorizontalRule(line: "***", previousLine: "Title"))
        #expect(LivePreviewEditing.isHorizontalRule(line: "---", previousLine: nil))
    }

    @Test func listItemParts() throws {
        let item = try #require(LivePreviewEditing.listItem(line: "  - one", lineStart: 10))
        #expect(item.indent == NSRange(location: 10, length: 2))
        #expect(item.marker == NSRange(location: 12, length: 1))
        #expect(item.prefix == NSRange(location: 12, length: 2))
        #expect(!item.isOrdered)
        let ordered = try #require(LivePreviewEditing.listItem(line: "12. two", lineStart: 0))
        #expect(ordered.marker == NSRange(location: 0, length: 3))
        #expect(ordered.isOrdered)
        #expect(LivePreviewEditing.listItem(line: "-no space", lineStart: 0) == nil)
        #expect(LivePreviewEditing.listItem(line: "- ", lineStart: 0) == nil)
    }

    @Test func footnoteReferenceAndDefinition() {
        let spans = LivePreviewEditing.footnoteSpans(in: "[^1]: Note, see [^a-b].", lineStart: 5)
        #expect(spans.map(\.isDefinition) == [true, false])
        #expect(spans[0].range == NSRange(location: 5, length: 4))
        #expect(spans[1].range == NSRange(location: 21, length: 6))
    }

    @Test func frontMatter() {
        #expect(LivePreviewEditing.frontMatterRange(text: "---\na: 1\n---\nbody") == NSRange(location: 0, length: 13))
        #expect(LivePreviewEditing.frontMatterRange(text: "---\na: 1\nbody") == nil)
        #expect(LivePreviewEditing.frontMatterRange(text: "text\n---\n") == nil)
    }
}

struct LivePreviewBlockRenderTests {
    private static let background = NSColor.white

    @MainActor
    private func makeView(_ text: String, width: CGFloat = 400) -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let storage = CodeAttributedString()
        storage.language = "markdown"
        storage.highlightr.setTheme(to: "xcode")
        let layoutManager = DecorationLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = MarkdownNSTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: 300),
            textContainer: container
        )
        textView.isEditable = true
        textView.isRichText = true
        textView.font = font
        textView.appearance = NSAppearance(named: .aqua)
        textView.drawsBackground = true
        textView.backgroundColor = Self.background
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

    /// Puts the caret on the last line, so every other line is inactive and styled.
    @MainActor
    private func style(_ textView: MarkdownNSTextView, _ coordinator: MarkdownTextView.Coordinator) {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: textView, fullDocument: true)
    }

    @Test @MainActor
    func ruleLineIsHiddenAndMarked() throws {
        let (view, coordinator) = makeView("Intro\n\n---\n\nTail")
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        let rule = ("Intro\n\n" as NSString).length
        #expect(storage.attribute(.fenBlockDecoration, at: rule, effectiveRange: nil) as? String == "rule")
        #expect(storage.attribute(.foregroundColor, at: rule, effectiveRange: nil) as? NSColor == Self.background)
        #expect(storage.attribute(.fenBlockDecoration, at: 0, effectiveRange: nil) == nil)
    }

    @Test @MainActor
    func ruleDrawsAcrossTheTextColumn() throws {
        let (view, coordinator) = makeView("Intro\n\n---\n\nTail")
        style(view, coordinator)
        let layoutManager = try #require(view.layoutManager)
        let ruleIndex = ("Intro\n\n" as NSString).length
        let line = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: ruleIndex),
            effectiveRange: nil
        )
        let y = Int(line.midY + view.textContainerOrigin.y)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = bitmap.pixelsWide / Int(view.bounds.width)
        func dark(_ x: Int, _ row: Int) -> Bool {
            (bitmap.colorAt(x: x * scale, y: row * scale)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.9
        }
        // Far right of the line: no text could be there, so only the rule can have drawn it.
        #expect(dark(300, y) || dark(300, y - 1))
        #expect(!dark(300, y + 8))
    }

    @Test @MainActor
    func hangingIndentAndAccentMarkerOnAList() throws {
        let long = String(repeating: "word ", count: 30)
        let (view, coordinator) = makeView("- \(long)\n\nTail")
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        let style = try #require(storage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent > 8)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .controlAccentColor)
    }

    @Test @MainActor
    func footnoteReferenceIsRaisedAndSmaller() throws {
        let (view, coordinator) = makeView("Claim[^1] here.\n\nTail")
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        let id = ("Claim[^" as NSString).length
        #expect((storage.attribute(.baselineOffset, at: id, effectiveRange: nil) as? CGFloat ?? 0) > 0)
        let font = try #require(storage.attribute(.font, at: id, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize < 14)
        let bracket = try #require(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        #expect(bracket.pointSize < 1)
    }

    @Test @MainActor
    func turningLivePreviewOffRestoresEverything() throws {
        let text = "Claim[^1] here.\n\n- item\n\n---\n\nTail"
        let (view, coordinator) = makeView(text)
        let storage = try #require(view.textStorage)
        let before = NSAttributedString(attributedString: storage)
        style(view, coordinator)
        #expect(storage != before)
        coordinator.parent.isLivePreviewEnabled = false
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        for key in [NSAttributedString.Key.fenBlockDecoration, .baselineOffset, .livePreviewOriginalParagraphStyle] {
            var found = false
            storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                found = found || value != nil
            }
            #expect(!found, "\(key.rawValue) left behind")
        }
        #expect(storage.string == before.string)
        for index in 0 ..< storage.length {
            let now = storage.attributes(at: index, effectiveRange: nil)
            let was = before.attributes(at: index, effectiveRange: nil)
            #expect(now[.paragraphStyle] as? NSParagraphStyle == was[.paragraphStyle] as? NSParagraphStyle)
            #expect(now[.font] as? NSFont == was[.font] as? NSFont)
            #expect(now[.foregroundColor] as? NSColor == was[.foregroundColor] as? NSColor)
        }
    }

    @Test @MainActor
    func frontMatterAndSetextAreNotRules() throws {
        let (view, coordinator) = makeView("---\ntitle: x\n---\n\nHeading\n---\n\nTail")
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        var found = false
        storage.enumerateAttribute(.fenBlockDecoration, in: NSRange(
            location: 0,
            length: storage.length
        )) { value, _, _ in
            found = found || value != nil
        }
        #expect(!found)
    }

    @Test @MainActor
    func theCaretLineStaysRaw() throws {
        let (view, coordinator) = makeView("Intro\n\n---\n\nTail")
        view.setSelectedRange(NSRange(location: ("Intro\n\n" as NSString).length + 1, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        let storage = try #require(view.textStorage)
        #expect(storage
            .attribute(.fenBlockDecoration, at: ("Intro\n\n" as NSString).length, effectiveRange: nil) == nil)
    }
}
