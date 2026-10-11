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

    @Test func tableNeedsADelimiterLineWithTheSameCellCount() {
        let table = "| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |\n\nafter"
        let blocks = LivePreviewEditing.tables(in: table, excluding: [])
        #expect(blocks.count == 1)
        #expect(blocks[0].lines.count == 4)
        #expect(blocks[0].header == NSRange(location: 0, length: 9))
        #expect(LivePreviewEditing.tables(in: "| a | b |\n|---|\n| 1 | 2 |", excluding: []).isEmpty)
        #expect(LivePreviewEditing.tables(in: "a | b\nplain text", excluding: []).isEmpty)
        #expect(LivePreviewEditing.tables(in: "a | b\n--|--\n1 | 2", excluding: []).count == 1)
    }

    @Test func tableInsideAFenceIsNotATable() {
        let text = "```\n| a | b |\n|---|---|\n```"
        let fenced = LivePreviewEditing.fencedRanges(text: text)
        #expect(LivePreviewEditing.tables(in: text, excluding: fenced).isEmpty)
    }

    @Test func tableCellsAreTrimmedAndEscapedPipesDoNotSplit() {
        let line = "| a \\| b |  c |"
        let cells = LivePreviewEditing.tableCells(line: line, lineStart: 0)
            .map { (line as NSString).substring(with: $0) }
        #expect(cells == ["a \\| b", "c"])
        let bare = "x | y"
        #expect(LivePreviewEditing.tableCells(line: bare, lineStart: 3) == [
            NSRange(location: 3, length: 1), NSRange(location: 7, length: 1),
        ])
        #expect(LivePreviewEditing.tablePipes(line: line, lineStart: 0).count == 3)
    }

    @Test func frontMatter() {
        #expect(LivePreviewEditing.frontMatterRange(text: "---\na: 1\n---\nbody") == NSRange(location: 0, length: 13))
        #expect(LivePreviewEditing.frontMatterRange(text: "---\na: 1\nbody") == nil)
        #expect(LivePreviewEditing.frontMatterRange(text: "text\n---\n") == nil)
    }
}

struct LivePreviewBlockRenderTests {
    static let background = NSColor.white

    @MainActor
    func makeView(_ text: String, width: CGFloat = 400) -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
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
    func style(_ textView: MarkdownNSTextView, _ coordinator: MarkdownTextView.Coordinator) {
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
        let (view, coordinator) = makeView("1. \(long)\n\nTail")
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        let style = try #require(storage.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle)
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

    // MARK: - Code blocks and tables

    @MainActor
    func bitmap(of view: MarkdownNSTextView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// 1 is the white editor background. Lower is darker. Coordinates are in points.
    @MainActor
    func brightness(_ rep: NSBitmapImageRep, _ view: NSView, x: CGFloat, y: CGFloat) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
    }

    @MainActor
    func fragment(_ view: MarkdownNSTextView, at character: Int) throws -> CGRect {
        let layoutManager = try #require(view.layoutManager)
        let rect = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: character), effectiveRange: nil
        )
        return rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    @Test @MainActor
    func fencedCodeGetsAPanelAndItsTextIsUntouched() throws {
        let text = "Intro\n\n```\nlet a = 1\n```\n\nTail"
        let (view, coordinator) = makeView(text)
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        let code = (text as NSString).range(of: "let a").location
        #expect(storage.attribute(.fenBlockDecoration, at: code, effectiveRange: nil) as? String == "codeBlock")
        #expect(storage.attribute(.livePreviewTouched, at: code, effectiveRange: nil) == nil)
        let rep = try bitmap(of: view)
        let inside = try fragment(view, at: code)
        let outside = try fragment(view, at: 0)
        // Far right of the line: no text reaches it, so only the panel can tint it.
        #expect(brightness(rep, view, x: 300, y: inside.midY) < 0.99)
        #expect(brightness(rep, view, x: 300, y: outside.midY) > 0.99)
    }

    @Test @MainActor
    func theCodePanelStaysWhileTheCaretIsInsideTheFence() throws {
        let text = "```\nlet a = 1\n```\n\nTail"
        let (view, coordinator) = makeView(text)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.fenBlockDecoration, at: 6, effectiveRange: nil) as? String == "codeBlock")
    }

    private static let table = "| a | **b** |\n|---|---|\n| 1 | *two* |"

    @Test @MainActor
    func tableLinesAreBoldShadedAndTheDelimiterCollapses() throws {
        let text = "Intro\n\n\(Self.table)\n\nTail"
        let (view, coordinator) = makeView(text)
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        let ns = text as NSString
        let header = ns.range(of: "| a").location
        let delimiter = ns.range(of: "|---|---|").location
        let row = ns.range(of: "| 1").location
        #expect(storage.attribute(.fenBlockDecoration, at: header, effectiveRange: nil) as? String == "tableHeader")
        #expect(storage
            .attribute(.fenBlockDecoration, at: delimiter, effectiveRange: nil) as? String == "tableDelimiter")
        #expect(storage.attribute(.fenBlockDecoration, at: row, effectiveRange: nil) as? String == "tableRow")
        let headerFont = try #require(storage.attribute(.font, at: header + 2, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: headerFont).contains(.boldFontMask))
        let collapsed = try #require(storage.attribute(.font, at: delimiter + 1, effectiveRange: nil) as? NSFont)
        #expect(collapsed.pointSize < 1)
        // The pipes are hidden. A line is drawn in their place.
        #expect(storage.attribute(.fenTablePipe, at: row, effectiveRange: nil) as? Bool == true)
        #expect(storage.attribute(.foregroundColor, at: row, effectiveRange: nil) as? NSColor == Self.background)
    }

    @Test @MainActor
    func inlineMarkdownInsideCellsIsStyled() throws {
        let text = "Intro\n\n\(Self.table)\n\nTail"
        let (view, coordinator) = makeView(text)
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        let ns = text as NSString
        let stars = ns.range(of: "**b**").location
        let font = try #require(storage.attribute(.font, at: stars, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize < 1, "the ** markers are hidden")
        let italic = ns.range(of: "two").location
        let italicFont = try #require(storage.attribute(.font, at: italic, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
    }

    @Test @MainActor
    func tableDrawsABandAColumnLineAndRowRules() throws {
        let text = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nTail"
        let (view, coordinator) = makeView(text)
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        let ns = text as NSString
        let headerRect = try fragment(view, at: ns.range(of: "| a").location)
        let rowRect = try fragment(view, at: ns.range(of: "| 1").location)
        let rep = try bitmap(of: view)
        // Far right: no text there, so a tint can only be the header band or a rule.
        #expect(brightness(rep, view, x: 380, y: headerRect.midY) < 0.97, "header band")
        #expect(brightness(rep, view, x: 380, y: rowRect.midY) > 0.99, "no band on a body row")
        #expect(brightness(rep, view, x: 380, y: rowRect.maxY - 0.5) < 0.9, "line under the row")
        // The second pipe sits between the two cells: a vertical line runs through the row.
        let pipe = ns.range(of: "|", options: [], range: NSRange(location: ns.range(of: "| 1").location + 1, length: 8))
            .location
        let layoutManager = try #require(view.layoutManager)
        let glyph = layoutManager.glyphIndexForCharacter(at: pipe)
        let box = try layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: #require(view.textContainer)
        )
        let x = (view.textContainerOrigin.x + box.midX).rounded()
        #expect(brightness(rep, view, x: x, y: rowRect.minY + 2) < 0.9, "column line")
        #expect(storage.string == text)
    }

    @Test @MainActor
    func aPipeInProseIsNotATable() throws {
        let (view, coordinator) = makeView("Use **a | b** here.\n\nTail")
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.fenBlockDecoration, at: 0, effectiveRange: nil) == nil)
        let content = try #require(storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: content).contains(.boldFontMask))
        let marker = try #require(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(marker.pointSize < 1, "the ** marker is hidden because the line is styled")
    }

    @Test @MainActor
    func togglingOffRestoresCodeAndTableLines() throws {
        let text = "Intro\n\n```\nlet a = 1\n```\n\n\(Self.table)\n\nTail"
        let (view, coordinator) = makeView(text)
        let storage = try #require(view.textStorage)
        let before = NSAttributedString(attributedString: storage)
        style(view, coordinator)
        coordinator.parent.isLivePreviewEnabled = false
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        for index in 0 ..< storage.length {
            let now = storage.attributes(at: index, effectiveRange: nil)
            let was = before.attributes(at: index, effectiveRange: nil)
            #expect(now[.font] as? NSFont == was[.font] as? NSFont, "font at \(index)")
            #expect(now[.foregroundColor] as? NSColor == was[.foregroundColor] as? NSColor, "color at \(index)")
            for key in [NSAttributedString.Key.fenBlockDecoration, .fenBlockInk, .fenTablePipe] {
                #expect(now[key] == nil, "\(key.rawValue) at \(index)")
            }
        }
    }
}
