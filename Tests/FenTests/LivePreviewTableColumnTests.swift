import AppKit
@testable import FenCore
import Foundation
import Testing

/// Issue #135, phase 4: table columns line up whatever spacing the source has.
@MainActor
struct LivePreviewTableColumnTests {
    private static let ragged = "Intro\n\n| Name | Qty |\n|---|---|\n| apples | 3 |\n| **kiwi** and more | 12 |\n\nTail"

    private func make(_ text: String) throws -> (MarkdownNSTextView, MarkdownTextView.Coordinator) {
        let (view, coordinator) = makeLivePreviewView(text, width: 600)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        return (view, coordinator)
    }

    /// The x of every pipe on the line starting with `prefix`.
    private func pipeXs(_ view: MarkdownNSTextView, line prefix: String) throws -> [CGFloat] {
        let text = view.string as NSString
        let start = text.range(of: prefix).location
        let line = text.lineRange(for: NSRange(location: start, length: 0))
        let layoutManager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layoutManager.ensureLayout(for: container)
        return LivePreviewEditing.tablePipes(line: text.substring(with: line), lineStart: line.location).map {
            layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(forCharacterRange: $0, actualCharacterRange: nil), in: container
            ).minX
        }
    }

    @Test func pipesLineUpAcrossRowsOfDifferentWidths() throws {
        let (view, _) = try make(Self.ragged)
        let header = try pipeXs(view, line: "| Name")
        let apples = try pipeXs(view, line: "| apples")
        let kiwi = try pipeXs(view, line: "| **kiwi**")
        #expect(header.count == 3 && apples.count == 3 && kiwi.count == 3)
        for column in 0 ..< 3 {
            #expect(abs(header[column] - apples[column]) < 1, "Column \(column): header and row 1")
            #expect(abs(header[column] - kiwi[column]) < 1, "Column \(column): header and row 2")
        }
        #expect(view.string == Self.ragged, "Alignment never changes the text")
    }

    @Test func turningLivePreviewOffTakesTheSpacingAway() throws {
        let (view, coordinator) = try make(Self.ragged)
        let storage = try #require(view.textStorage)
        func hasKern() -> Bool {
            var kerned = false
            storage.enumerateAttribute(.kern, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                kerned = kerned || value != nil
            }
            return kerned
        }
        #expect(hasKern())
        coordinator.parent.isLivePreviewEnabled = false
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        #expect(!hasKern())
    }

    @Test func theCaretInATableShowsItsSourceAndLeavingAlignsItAgain() throws {
        let (view, coordinator) = try make(Self.ragged)
        let text = view.string as NSString
        let storage = try #require(view.textStorage)
        func kerns() -> Int {
            var count = 0
            storage.enumerateAttribute(.kern, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                count += value == nil ? 0 : 1
            }
            return count
        }
        let aligned = kerns()
        #expect(aligned > 0)
        view.setSelectedRange(NSRange(location: text.range(of: "| apples").location + 4, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: false)
        #expect(kerns() == 0, "The table is one paragraph, so it shows its source while the caret is in it")
        view.setSelectedRange(NSRange(location: text.length, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: false)
        #expect(kerns() == aligned)
        let header = try pipeXs(view, line: "| Name")
        let kiwi = try pipeXs(view, line: "| **kiwi**")
        for column in 0 ..< 3 {
            #expect(abs(header[column] - kiwi[column]) < 1)
        }
    }

    @Test func aTableWithoutOuterPipesAlignsToo() throws {
        let text = "a | b\n--|--\nlonger cell | x\ns | y\n\nTail"
        let (view, _) = try make(text)
        let first = try pipeXs(view, line: "a | b")
        let second = try pipeXs(view, line: "longer")
        let third = try pipeXs(view, line: "s | y")
        #expect(abs(first[0] - second[0]) < 1 && abs(first[0] - third[0]) < 1)
    }
}
