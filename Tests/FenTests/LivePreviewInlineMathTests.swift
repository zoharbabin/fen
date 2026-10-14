import AppKit
@testable import FenCore
import Foundation
import Testing

/// Which text counts as inline math (issue #135).
struct LivePreviewInlineMathDetectionTests {
    private func spans(
        _ text: String,
        _ math: LivePreviewEditing.MathDelimiters,
        start: Int = 0
    ) -> [LivePreviewEditing.Span] {
        LivePreviewEditing.inlineSpans(in: text, textStart: start, math: math)
    }

    private func sources(
        _ text: String,
        _ math: LivePreviewEditing.MathDelimiters = [.parentheses, .dollars]
    ) -> [String] {
        spans(text, math).compactMap {
            if case let .inlineMath(source) = $0.kind {
                source
            } else {
                nil
            }
        }
    }

    @Test func parenthesesAndDollarsAreFound() {
        #expect(sources(#"Area is \(x^2\) and $y$ here"#) == [#"\(x^2\)"#, "$y$"])
    }

    @Test func dollarsAreOnlyFoundWhenAsked() {
        #expect(sources("Area is $y$ here", .parentheses).isEmpty)
        #expect(sources(#"Area is \(y\) here"#, .parentheses) == [#"\(y\)"#])
        #expect(spans("$y$", []).isEmpty)
    }

    @Test(arguments: [
        "It costs $5 and $10.",
        "A lone $ sign",
        "$ x$ has a space after the opener",
        "$x $ has a space before the closer",
        "$$x$$ is display math",
        #"\$x\$ is escaped"#,
        "$x$5 is followed by a digit",
        "$x\ny$ spans two lines",
        #"\(unclosed"#,
        #"\(\)"#,
    ])
    func proseIsNotMath(_ text: String) {
        #expect(sources(text).isEmpty, "\(text) is not math")
    }

    @Test func aDollarInsideMathCanBeEscaped() {
        #expect(sources(#"$a\$b$"#) == [#"$a\$b$"#])
    }

    @Test func rangesPointAtTheDelimitersAndTheFormula() throws {
        let span = try #require(spans(#"ab \(x\) cd"#, .parentheses, start: 10).first)
        #expect(span.markerRanges == [NSRange(location: 13, length: 2), NSRange(location: 16, length: 2)])
        #expect(span.contentRange == NSRange(location: 15, length: 1))
    }

    @Test func emphasisInsideMathIsNotEmphasis() {
        let found = spans("$a*b*c$ and **bold**", [.dollars])
        #expect(found.count == 2)
        #expect(found.map(\.kind).contains(.bold))
        #expect(!found.map(\.kind).contains(.italic))
    }

    @Test func codeSpansKeepTheirDollars() {
        let found = spans("`$x$` and $y$", [.dollars])
        #expect(found.map(\.kind) == [.inlineCode, .inlineMath(source: "$y$")])
    }

    @MainActor @Test func settingsPickTheDelimiters() throws {
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: "inlinemath.\(UUID().uuidString)")))
        let kinds: Set<RenderedBlock.Kind> = [.inlineMath]
        #expect(LivePreviewSnapshots.mathDelimiters([], preferences: prefs) == [])
        #expect(LivePreviewSnapshots.mathDelimiters(kinds, preferences: prefs) == .parentheses)
        prefs.htmlMathJaxInlineDollar = true
        #expect(LivePreviewSnapshots.mathDelimiters(kinds, preferences: prefs) == [.parentheses, .dollars])
    }
}

/// The formula becomes a picture in the editor: hidden source, reserved width, a picture on the baseline.
@MainActor
@Suite(.serialized)
struct LivePreviewInlineMathStyleTests {
    private static let text = "Area is \\(x^2\\) here\n\nTail"
    private static let formula = NSRange(location: 8, length: 7)
    private static let background = NSColor.white

    private func withStub(
        size: CGSize = CGSize(width: 40, height: 20), baseline: CGFloat = 14,
        result: Bool = true, _ body: () async throws -> Void
    ) async throws {
        let saved = LivePreviewSnapshots.shared
        defer { LivePreviewSnapshots.shared = saved }
        LivePreviewSnapshots.shared = LivePreviewSnapshots(kinds: { [.inlineMath] }) { _ in
            result ? .init(image: solidImage(.red, width: size.width, height: size.height), baseline: baseline) : nil
        }
        try await body()
    }

    private func restyle(_ view: MarkdownNSTextView, _ coordinator: MarkdownTextView.Coordinator, caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
    }

    private func hasPicture(_ view: MarkdownNSTextView) -> Bool {
        view.textStorage?.attribute(.fenInlinePicture, at: Self.formula.location, effectiveRange: nil) != nil
    }

    private var tail: Int {
        (Self.text as NSString).length
    }

    @Test func theFormulaBecomesAPictureWhenItIsReady() async throws {
        try await withStub {
            let (view, coordinator) = makeLivePreviewView(Self.text, background: Self.background)
            let storage = try #require(view.textStorage)
            restyle(view, coordinator, caret: tail)
            #expect(!hasPicture(view), "Source shows until the picture is ready")
            let ready = try await pollUntilTrue { hasPicture(view) }
            #expect(ready)
            let font = try #require(storage.attribute(
                .font,
                at: Self.formula.location + 3,
                effectiveRange: nil
            ) as? NSFont)
            #expect(font.pointSize < 1, "The source shrinks to nothing")
            let kern = try #require(storage.attribute(
                .kern,
                at: Self.formula.location,
                effectiveRange: nil
            ) as? CGFloat)
            #expect(kern == 40 + 2 * LivePreviewBlockStyle.formulaMargin, "The first character keeps the width")
            #expect(view.string == Self.text, "The document text never changes")
        }
    }

    @Test func theParagraphWithTheCaretShowsSource() async throws {
        try await withStub {
            let (view, coordinator) = makeLivePreviewView(Self.text, background: Self.background)
            restyle(view, coordinator, caret: tail)
            let ready = try await pollUntilTrue { hasPicture(view) }
            #expect(ready)
            restyle(view, coordinator, caret: Self.formula.location + 2)
            #expect(!hasPicture(view), "The formula is source again while you edit it")
            let font = try #require(view.textStorage?.attribute(
                .font,
                at: Self.formula.location,
                effectiveRange: nil
            ) as? NSFont)
            #expect(font.pointSize > 5)
            restyle(view, coordinator, caret: tail)
            #expect(hasPicture(view), "And a picture again when you leave")
        }
    }

    @Test func aFormulaThatFailsStaysSource() async throws {
        try await withStub(result: false) {
            let (view, coordinator) = makeLivePreviewView(Self.text, background: Self.background)
            restyle(view, coordinator, caret: tail)
            let source = try #require(
                LivePreviewSnapshots.key(forFormula: #"\(x^2\)"#, background: Self.background)
            )
            let ready = try await pollUntilTrue { LivePreviewSnapshots.shared.hasFailed(source) }
            #expect(ready)
            restyle(view, coordinator, caret: tail)
            #expect(!hasPicture(view))
        }
    }

    @Test func turningLivePreviewOffPutsTheTextBack() async throws {
        try await withStub {
            let (view, coordinator) = makeLivePreviewView(Self.text, background: Self.background)
            let storage = try #require(view.textStorage)
            let before = (storage.attribute(.font, at: Self.formula.location, effectiveRange: nil) as? NSFont)?
                .pointSize
            restyle(view, coordinator, caret: tail)
            let ready = try await pollUntilTrue { hasPicture(view) }
            #expect(ready)
            storage.beginEditing()
            LivePreviewBlockStyle.restore(in: NSRange(location: 0, length: storage.length), storage: storage)
            storage.endEditing()
            #expect(!hasPicture(view))
            #expect(storage.attribute(.kern, at: Self.formula.location, effectiveRange: nil) == nil)
            #expect((storage.attribute(.font, at: Self.formula.location, effectiveRange: nil) as? NSFont)?
                .pointSize == before)
        }
    }

    /// The picture's box, in view points, from the red pixels the view drew.
    private func redBox(in view: MarkdownNSTextView) throws -> CGRect? {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        var box: CGRect?
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.redComponent > 0.9, color.greenComponent < 0.2 else { continue }
                let point = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
                box = box.map { $0.union(point) } ?? point
            }
        }
        return box
    }

    @Test func thePictureIsDrawnOnTheBaselineWhereTheSourceWas() async throws {
        try await withStub(size: CGSize(width: 40, height: 20), baseline: 14) {
            let (view, coordinator) = makeLivePreviewView(Self.text, background: Self.background)
            restyle(view, coordinator, caret: tail)
            let ready = try await pollUntilTrue { hasPicture(view) }
            #expect(ready)
            let layout = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: Self.formula.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let baseline = fragment.minY + layout.location(forGlyphAt: glyph).y + view.textContainerOrigin.y
            let drawn = try #require(try redBox(in: view), "The picture is drawn")
            #expect(abs(drawn.minX - (box.minX + view.textContainerOrigin.x + LivePreviewBlockStyle.formulaMargin)) <=
                1.5)
            #expect(abs(drawn.maxY - (baseline - 14 + 20)) <= 1.5, "Its baseline sits on the text baseline")
            #expect(abs(drawn.width - 40) <= 1.5 && abs(drawn.height - 20) <= 1.5)
            let after = layout.boundingRect(forGlyphRange: NSRange(location: glyph + 7, length: 1), in: container)
            #expect(after.minX - box.minX >= 40, "The text after the formula starts after the picture")
        }
    }

    @Test func aTallPictureGrowsItsLineAndStaysInsideIt() async throws {
        try await withStub(size: CGSize(width: 30, height: 60), baseline: 40) {
            let (view, coordinator) = makeLivePreviewView(Self.text, background: Self.background)
            restyle(view, coordinator, caret: tail)
            let ready = try await pollUntilTrue { hasPicture(view) }
            #expect(ready)
            let layout = try #require(view.layoutManager)
            try layout.ensureLayout(for: #require(view.textContainer))
            let glyph = layout.glyphIndexForCharacter(at: Self.formula.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = fragment.minY + layout.location(forGlyphAt: glyph).y
            #expect(baseline - 40 >= fragment.minY - 0.5, "The top of the picture is inside the line")
            #expect(baseline - 40 + 60 <= fragment.maxY + 0.5, "The bottom of the picture is inside the line")
        }
    }

    @Test func restylingDoesNotGrowTheLineAgain() async throws {
        try await withStub(size: CGSize(width: 30, height: 60), baseline: 40) {
            let (view, coordinator) = makeLivePreviewView(Self.text, background: Self.background)
            restyle(view, coordinator, caret: tail)
            let ready = try await pollUntilTrue { hasPicture(view) }
            #expect(ready)
            @MainActor func spacing() -> CGFloat {
                (view.textStorage?.attribute(.paragraphStyle, at: Self.formula.location, effectiveRange: nil)
                    as? NSParagraphStyle)?.lineSpacing ?? -1
            }
            let first = spacing()
            #expect(first > 0)
            for _ in 0 ..< 3 {
                restyle(view, coordinator, caret: Self.formula.location + 2)
                restyle(view, coordinator, caret: tail)
            }
            #expect(spacing() == first)
        }
    }

    @Test func aSmallPictureLeavesTheLineAlone() async throws {
        try await withStub(size: CGSize(width: 30, height: 12), baseline: 10) {
            let (view, coordinator) = makeLivePreviewView(Self.text, background: Self.background)
            restyle(view, coordinator, caret: tail)
            let ready = try await pollUntilTrue { hasPicture(view) }
            #expect(ready)
            let style = view.textStorage?.attribute(
                .paragraphStyle,
                at: Self.formula.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect((style?.minimumLineHeight ?? 0) == 0)
        }
    }
}
