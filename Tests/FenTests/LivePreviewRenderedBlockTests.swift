import AppKit
@testable import FenCore
import Foundation
import Highlightr
import Testing
import WebKit

/// Issue #135, phase 3: Mermaid, `$$` math and map blocks drawn as pictures.
@MainActor
struct LivePreviewRenderedBlockDetectionTests {
    private func blocks(_ text: String, _ kinds: Set<RenderedBlock.Kind> = Set(RenderedBlock.Kind.allCases))
        -> [RenderedBlock] {
        LivePreviewEditing.renderedBlocks(
            in: text, fenced: LivePreviewEditing.fencedRanges(text: text), kinds: kinds
        )
    }

    @Test func mermaidFenceIsABlockWithItsSource() throws {
        let text = "Intro\n\n```mermaid\ngraph TD; A-->B;\n```\n\nTail"
        let block = try #require(blocks(text).first)
        #expect(block.kind == .mermaid)
        #expect(block.source == "```mermaid\ngraph TD; A-->B;\n```")
        #expect((text as NSString).substring(with: block.range) == "```mermaid\ngraph TD; A-->B;\n```\n")
    }

    @Test func geojsonAndTopojsonAreMaps() {
        let text = "```geojson\n{}\n```\n\n```TopoJSON\n{}\n```"
        #expect(blocks(text).map(\.kind) == [.map, .map])
    }

    @Test func otherFencesAndUnclosedFencesAreNotBlocks() {
        #expect(blocks("```swift\nlet x = 1\n```").isEmpty)
        #expect(blocks("```mermaid\ngraph TD; A-->B;").isEmpty)
    }

    @Test func onlyTheEnabledKindsAreBlocks() {
        let text = "```mermaid\ngraph TD; A-->B;\n```\n\n$$x$$\n\n```geojson\n{}\n```"
        #expect(blocks(text, []).isEmpty)
        #expect(blocks(text, [.math]).map(\.kind) == [.math])
        #expect(blocks(text, [.mermaid, .map]).map(\.kind) == [.mermaid, .map])
    }

    @Test func mathOnOneLineAndOnSeveral() throws {
        let one = try #require(blocks("a\n\n$$ x^2 $$\n\nb").first)
        #expect(one.source == "$$ x^2 $$")
        let many = try #require(blocks("a\n\n$$\nx^2\n+ y\n$$\n\nb").first)
        #expect(many.source == "$$\nx^2\n+ y\n$$")
        #expect(blocks("$$\nx\n+ y $$").count == 1, "A line that ends with $$ closes the block")
    }

    @Test func aStrayDollarPairIsNotMath() {
        #expect(blocks("$$ price\n\nnext paragraph $$").isEmpty, "A blank line ends the search")
        #expect(blocks("costs $$ and more").isEmpty)
        #expect(blocks("$$").isEmpty)
    }

    @Test func mathInsideACodeFenceOrFrontMatterIsLeftAlone() {
        #expect(blocks("```\n$$\nx\n$$\n```").isEmpty)
        #expect(blocks("---\ntitle: $$x$$\n---\n\nbody").isEmpty)
    }

    @Test func contextWidensARangeToWholeBlocks() {
        let text = "Intro\n\n```mermaid\na\n\nb\n```\n\nTail"
        let context = LivePreviewBlockContext(text: text, rendering: [.mermaid])
        let block = context.rendered[0]
        let inside = NSRange(location: block.range.location + 12, length: 0)
        #expect(context.widened(inside) == block.range)
        #expect(context.widened(NSRange(location: 0, length: 3)) == NSRange(location: 0, length: 3))
        #expect(context.renderedBlock(at: block.range.location + 14) == block)
        #expect(context.renderedBlock(at: 0) == nil)
        #expect(LivePreviewBlockContext(text: text).rendered.isEmpty)
    }

    @Test func theKindsFollowThePreviewSettings() throws {
        let suite = "livepreview.kinds.\(UUID().uuidString)"
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: suite)))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        prefs.htmlMermaid = false
        prefs.htmlMathJax = false
        prefs.htmlGeoJSONMaps = false
        #expect(LivePreviewSnapshots.enabledKinds(prefs).isEmpty)
        prefs.htmlMermaid = true
        #expect(LivePreviewSnapshots.enabledKinds(prefs) == [.mermaid])
        prefs.htmlMathJax = true
        prefs.htmlGeoJSONMaps = true
        #expect(LivePreviewSnapshots.enabledKinds(prefs) == [.mermaid, .math, .map])
    }
}

/// The text view in a block-aware Live Preview, with a stub renderer so the test sees the editor and not WebKit.
@MainActor
@Suite(.serialized)
struct LivePreviewRenderedBlockRenderTests {
    private static let background = NSColor.white
    private static let text = "Intro\n\n```mermaid\ngraph TD; A-->B;\n```\n\nTail"
    private static let blockStart = ("Intro\n\n" as NSString).length

    private func makeView(_ text: String) -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let storage = CodeAttributedString()
        storage.language = "markdown"
        storage.highlightr.setTheme(to: "xcode")
        let layoutManager = DecorationLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        textView.isEditable = true
        textView.isRichText = true
        textView.font = font
        textView.appearance = NSAppearance(named: .aqua)
        textView.drawsBackground = true
        textView.backgroundColor = Self.background
        textView.string = text
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
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

    /// Runs `body` with a stub renderer that returns a 120 x 60 red picture.
    private func withStub(
        kinds: Set<RenderedBlock.Kind> = [.mermaid], _ body: (LivePreviewSnapshots) async throws -> Void
    ) async throws {
        let saved = LivePreviewSnapshots.shared
        defer { LivePreviewSnapshots.shared = saved }
        let stub = LivePreviewSnapshots(shows: kinds) { _ in solidImage(.red, width: 120, height: 60) }
        LivePreviewSnapshots.shared = stub
        try await body(stub)
    }

    private func restyle(_ view: MarkdownNSTextView, _ coordinator: MarkdownTextView.Coordinator, caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
    }

    private func hasPicture(_ view: MarkdownNSTextView) -> Bool {
        view.textStorage?.attribute(.fenBlockImage, at: Self.blockStart, effectiveRange: nil) != nil
    }

    @Test
    func theBlockBecomesAPictureWhenItIsReady() async throws {
        try await withStub { _ in
            let (view, coordinator) = makeView(Self.text)
            let storage = try #require(view.textStorage)
            restyle(view, coordinator, caret: (Self.text as NSString).length)
            #expect(!hasPicture(view), "Source shows until the picture is ready")
            let arrived = try await pollUntilTrue { hasPicture(view) }
            #expect(arrived, "The coordinator restyles when the picture arrives")
            let font = try #require(storage.attribute(.font, at: Self.blockStart + 14, effectiveRange: nil) as? NSFont)
            #expect(font.pointSize < 1, "The source lines collapse")
            let style = try #require(
                storage.attribute(.paragraphStyle, at: Self.blockStart, effectiveRange: nil) as? NSParagraphStyle
            )
            #expect(style.minimumLineHeight == 60 + 2 * LivePreviewBlockStyle.pictureMargin)
            #expect(view.string == Self.text, "The document text never changes")
        }
    }

    @Test
    func thePictureIsDrawnWhereTheBlockWas() async throws {
        try await withStub { _ in
            let (view, coordinator) = makeView(Self.text)
            restyle(view, coordinator, caret: (Self.text as NSString).length)
            _ = try await pollUntilTrue { hasPicture(view) }
            let layoutManager = try #require(view.layoutManager)
            let line = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: Self.blockStart), effectiveRange: nil
            )
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = bitmap.pixelsWide / Int(view.bounds.width)
            func isRed(_ x: CGFloat, _ y: CGFloat) -> Bool {
                guard let color = bitmap.colorAt(x: Int(x) * scale, y: Int(y) * scale)?.usingColorSpace(.sRGB)
                else { return false }
                return color.redComponent > 0.9 && color.greenComponent < 0.2
            }
            let top = line.minY + view.textContainerOrigin.y
            let left = view.textContainerOrigin.x + (view.textContainer?.lineFragmentPadding ?? 0)
            #expect(isRed(left + 60, top + LivePreviewBlockStyle.pictureMargin + 30))
            #expect(!isRed(left + 200, top + 30), "The picture is 120 points wide")
            #expect(!isRed(left + 60, top + line.height + 20), "Nothing is drawn below the block")
        }
    }

    @Test
    func theCaretInsideShowsTheSourceAndLeavingBringsThePictureBack() async throws {
        try await withStub { _ in
            let (view, coordinator) = makeView(Self.text)
            let end = (Self.text as NSString).length
            restyle(view, coordinator, caret: end)
            _ = try await pollUntilTrue { hasPicture(view) }
            let storage = try #require(view.textStorage)

            view.setSelectedRange(NSRange(location: Self.blockStart + 14, length: 0))
            coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: false)
            #expect(!hasPicture(view))
            let font = try #require(storage.attribute(.font, at: Self.blockStart + 14, effectiveRange: nil) as? NSFont)
            #expect(font.pointSize > 10, "The source is readable again")
            #expect(
                storage.attribute(.fenBlockDecoration, at: Self.blockStart, effectiveRange: nil) as? String
                    == "codeBlock",
                "The raw fence still has its panel"
            )

            view.setSelectedRange(NSRange(location: end, length: 0))
            coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: false)
            #expect(hasPicture(view))
        }
    }

    @Test
    func aBlockWithABlankLineInsideIsRestyledAsAWhole() async throws {
        try await withStub { _ in
            let text = "Intro\n\n```mermaid\ngraph TD;\n\nA-->B;\n```\n\nTail"
            let (view, coordinator) = makeView(text)
            let end = (text as NSString).length
            restyle(view, coordinator, caret: end)
            _ = try await pollUntilTrue { hasPicture(view) }
            let storage = try #require(view.textStorage)
            let lastFence = (text as NSString).range(of: "```\n\nTail").location
            view.setSelectedRange(NSRange(location: lastFence + 1, length: 0))
            coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: false)
            for index in [Self.blockStart, Self.blockStart + 12, lastFence] {
                let font = try #require(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                #expect(font.pointSize > 10, "Offset \(index) shows its source")
            }
            #expect(!hasPicture(view))
        }
    }

    @Test
    func aKindThatIsOffStaysSource() async throws {
        try await withStub(kinds: []) { stub in
            let (view, coordinator) = makeView(Self.text)
            restyle(view, coordinator, caret: (Self.text as NSString).length)
            #expect(!hasPicture(view))
            #expect(stub.image(for: .init(kind: .mermaid, source: "x", width: 360, dark: false)) == nil)
            let storage = try #require(view.textStorage)
            #expect(storage.attribute(.fenBlockDecoration, at: Self.blockStart, effectiveRange: nil) as? String
                == "codeBlock")
        }
    }

    @Test
    func mathBlocksBecomePicturesToo() async throws {
        try await withStub(kinds: [.math]) { _ in
            let text = "Intro\n\n$$\nx^2 + y^2\n$$\n\nTail"
            let (view, coordinator) = makeView(text)
            restyle(view, coordinator, caret: (text as NSString).length)
            let arrived = try await pollUntilTrue { hasPicture(view) }
            #expect(arrived)
        }
    }

    @Test
    func turningLivePreviewOffRemovesThePicture() async throws {
        try await withStub { _ in
            let (view, coordinator) = makeView(Self.text)
            let storage = try #require(view.textStorage)
            let before = NSAttributedString(attributedString: storage)
            restyle(view, coordinator, caret: (Self.text as NSString).length)
            _ = try await pollUntilTrue { hasPicture(view) }
            coordinator.parent.isLivePreviewEnabled = false
            coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
            for key in [NSAttributedString.Key.fenBlockImage, .fenBlockDecoration, .livePreviewOriginalParagraphStyle] {
                var found = false
                storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                    found = found || value != nil
                }
                #expect(!found, "\(key.rawValue) left behind")
            }
            #expect(storage.string == before.string)
            for index in 0 ..< storage.length {
                let attributes = storage.attributes(at: index, effectiveRange: nil)
                #expect((attributes[.font] as? NSFont)?.pointSize ?? 14 > 10, "Offset \(index) is still collapsed")
                #expect(attributes[.foregroundColor] as? NSColor != Self.background, "Offset \(index) is still hidden")
            }
        }
    }
}

/// The real renderer, end to end: Markdown goes through the export pipeline into an offscreen web view, and the
/// snapshot comes back as an image.
@MainActor
@Suite(.serialized)
struct LivePreviewWebSnapshotTests {
    private func preferences() throws -> Preferences {
        let prefs = try Preferences(
            defaults: #require(UserDefaults(suiteName: "livepreview.snapshot.\(UUID().uuidString)"))
        )
        prefs.htmlMermaid = true
        prefs.htmlMathJax = true
        return prefs
    }

    private func render(_ kind: RenderedBlock.Kind, _ source: String, dark: Bool = false) async throws -> NSImage? {
        let prefs = try preferences()
        return await LivePreviewWebSnapshot.render(key(kind, source, dark: dark), preferences: prefs)
    }

    private func key(_ kind: RenderedBlock.Kind, _ source: String, dark: Bool = false) -> LivePreviewSnapshots.Key {
        .init(kind: kind, source: source, width: 400, dark: dark)
    }

    /// The share of pixels that are not fully transparent.
    private func inkShare(of image: NSImage) throws -> Double {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var inked = 0
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                inked += 1
            }
        }
        return Double(inked) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
    }

    @Test
    func aMermaidPictureHasNoCardAroundIt() async throws {
        let image = try #require(try await render(.mermaid, "```mermaid\ngraph TD; A-->B; B-->C;\n```"))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        // The theme's card is a gray border and fill. Its left edge and top-left corner would be inked.
        for y in 0 ..< bitmap.pixelsHigh {
            #expect((bitmap.colorAt(x: 0, y: y)?.alphaComponent ?? 0) < 0.05)
        }
        for x in 0 ..< bitmap.pixelsWide {
            #expect((bitmap.colorAt(x: x, y: 0)?.alphaComponent ?? 0) < 0.05)
        }
    }

    @Test
    func aMermaidDiagramBecomesAnImageOfTheRequestedWidth() async throws {
        let image = try #require(try await render(.mermaid, "```mermaid\ngraph TD; A-->B; B-->C;\n```"))
        #expect(image.size.width == 400)
        #expect(image.size.height > 40)
        #expect(try inkShare(of: image) > 0.01, "The diagram has visible content")
    }

    @Test
    func aTallBlockIsScaledDownNotCutOff() async throws {
        let nodes = (0 ..< 40).map { "N\($0)[Step \($0)]" }.joined(separator: " --> ")
        let image = try #require(try await render(.mermaid, "```mermaid\ngraph TD; \(nodes);\n```"))
        #expect(image.size.height <= LivePreviewWebSnapshot.maxPictureHeight + 1, "Within a point of the limit")
        #expect(image.size.width < 400, "The picture shrank to fit instead of keeping the width and cropping")
        // The last step sits at the bottom of the diagram. A cropped picture would end in the middle of it.
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var inkInLastRows = 0
        for y in (bitmap.pixelsHigh - bitmap.pixelsHigh / 20) ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                inkInLastRows += 1
            }
        }
        #expect(inkInLastRows > 0, "The last step is in the picture")
    }

    @Test
    func aBlockUnderTheLimitKeepsItsWidth() {
        #expect(LivePreviewWebSnapshot.pictureWidth(blockWidth: 400, blockHeight: 1600) == 400)
        #expect(LivePreviewWebSnapshot.pictureWidth(blockWidth: 400, blockHeight: 3200) == 200)
    }

    @Test
    func aBrokenDiagramGivesNoImageSoTheSourceStaysVisible() async throws {
        let image = try await render(.mermaid, "```mermaid\nthis is not a diagram ->>> [\n```")
        #expect(image == nil)
    }

    @Test
    func mathBecomesAnImage() async throws {
        let image = try #require(try await render(.math, "$$\\frac{a}{b} + \\sqrt{x}$$"))
        #expect(image.size.height > 10)
        #expect(try inkShare(of: image) > 0.005)
    }

    @Test
    func theBackgroundIsTransparentSoTheEditorColorShowsThrough() async throws {
        let image = try #require(try await render(.math, "$$x$$"))
        #expect(try inkShare(of: image) < 0.5, "Most of the picture is not painted")
    }

    @Test
    func theDarkKeyUsesTheDarkTheme() async throws {
        func brightness(_ image: NSImage) throws -> Double {
            let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            var total = 0.0, count = 0.0
            for y in 0 ..< bitmap.pixelsHigh {
                for x in 0 ..< bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5
                    else { continue }
                    total += color.brightnessComponent
                    count += 1
                }
            }
            return count == 0 ? 0 : total / count
        }
        let source = "$$\\sum_{i=1}^{n} i$$"
        let light = try #require(try await render(.math, source))
        let dark = try #require(try await render(.math, source, dark: true))
        #expect(try brightness(dark) > brightness(light) + 0.3, "Dark mode draws light glyphs")
    }
}
