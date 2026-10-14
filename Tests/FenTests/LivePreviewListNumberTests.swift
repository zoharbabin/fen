import AppKit
@testable import FenCore
import Foundation
import Testing

/// Issue #135, phase 4: an ordered list shows the numbers Markdown gives it, not the ones typed.
@MainActor
struct LivePreviewListNumberTests {
    private func ordinals(_ text: String) -> [Int: Int] {
        let fenced = LivePreviewEditing.fencedRanges(text: text)
        let front = LivePreviewEditing.frontMatterRange(text: text).map { NSMaxRange($0) } ?? 0
        return LivePreviewEditing.listOrdinals(in: text, excluding: fenced, frontMatterEnd: front)
    }

    /// The numbers by line index, so a test reads like the document.
    private func shown(_ lines: [String]) -> [Int: Int] {
        let text = lines.joined(separator: "\n")
        var starts: [Int: Int] = [:]
        var offset = 0
        for (index, line) in lines.enumerated() {
            starts[offset] = index
            offset += (line as NSString).length + 1
        }
        return ordinals(text).reduce(into: [:]) { $0[starts[$1.key]!] = $1.value }
    }

    @Test func aListNumberedWithTheSameNumberCountsUp() {
        #expect(shown(["1. a", "1. b", "1. c"]) == [1: 2, 2: 3])
    }

    @Test func aListThatIsAlreadyInOrderNeedsNoChange() {
        #expect(shown(["1. a", "2. b", "3. c"]).isEmpty)
        #expect(shown(["3. a", "4. b"]).isEmpty, "A list starts at its first number")
    }

    @Test func theFirstNumberSetsTheStart() {
        #expect(shown(["5. a", "1. b", "1. c"]) == [1: 6, 2: 7])
    }

    @Test func aBlankLineOrNestedItemsDoNotEndTheList() {
        #expect(shown(["1. a", "", "1. b"]) == [2: 2])
        #expect(shown(["1. a", "   - x", "   - y", "1. b"]) == [3: 2])
        #expect(shown(["1. a", "   1. x", "   1. y", "1. b"]) == [2: 2, 3: 2], "A nested list counts on its own")
    }

    @Test func aParagraphOrHeadingEndsTheList() {
        #expect(shown(["1. a", "", "Text", "", "1. b", "1. c"]) == [5: 2])
        #expect(shown(["1. a", "# Head", "1. b", "1. c"]) == [3: 2])
    }

    @Test func aLineRightUnderAnItemContinuesIt() {
        #expect(shown(["1. a", "lazy", "1. b"]) == [2: 2])
    }

    @Test func aNewDelimiterOrABulletStartsAnotherList() {
        #expect(shown(["1. a", "1) b", "1) c"]) == [2: 2])
        #expect(shown(["1. a", "- b", "1. c"]).isEmpty)
    }

    @Test func codeFencesAndFrontMatterAreSkipped() {
        #expect(shown(["1. a", "```", "1. x", "1. y", "```", "1. b"]).isEmpty, "A fence ends the list")
        #expect(shown(["---", "k: 1", "---", "", "1. a", "1. b"]) == [5: 2])
    }

    @Test func theMarkerIsHiddenAndTheRightNumberIsDrawn() throws {
        let text = "Intro\n\n1. one\n1. two\n1. three\n\nTail"
        let (view, coordinator) = makeLivePreviewView(text)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        let storage = try #require(view.textStorage)
        let second = (text as NSString).range(of: "1. two").location
        let third = (text as NSString).range(of: "1. three").location
        #expect(storage.attribute(.fenListOrdinal, at: second, effectiveRange: nil) as? String == "2.")
        #expect(storage.attribute(.fenListOrdinal, at: third, effectiveRange: nil) as? String == "3.")
        #expect(storage.attribute(
            .fenListOrdinal,
            at: (text as NSString).range(of: "1. one").location,
            effectiveRange: nil
        ) == nil)
        #expect(view.string == text, "The text keeps the numbers you typed")

        let layoutManager = try #require(view.layoutManager)
        let glyph = layoutManager.glyphIndexForCharacter(at: second)
        let container = try #require(view.textContainer)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 2), in: container)
        rect = rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = bitmap.pixelsWide / Int(view.bounds.width)
        var inked = 0
        for x in Int(rect.minX) * scale ..< Int(rect.maxX) * scale {
            for y in Int(rect.minY) * scale ..< Int(rect.maxY) * scale {
                let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                if let color, color.redComponent < 0.9 || color.greenComponent < 0.9 || color.blueComponent < 0.9 {
                    inked += 1
                }
            }
        }
        #expect(inked > 10, "The drawn number shows where the hidden marker is")
    }

    @Test func theCaretOnAnItemShowsTheNumbersYouTyped() throws {
        let text = "1. one\n1. two\n1. three\n\nTail"
        let (view, coordinator) = makeLivePreviewView(text)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        let second = (text as NSString).range(of: "1. two").location
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.fenListOrdinal, at: second, effectiveRange: nil) != nil)
        view.setSelectedRange(NSRange(location: second + 3, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: false)
        #expect(storage.attribute(.fenListOrdinal, at: second, effectiveRange: nil) == nil)
        #expect(storage.attribute(.fenBlockDecoration, at: second, effectiveRange: nil) == nil)
    }
}
