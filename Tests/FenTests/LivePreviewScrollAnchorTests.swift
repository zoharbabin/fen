import AppKit
@testable import FenCore
import Foundation
import Testing

/// Issue #135: the editor/preview scroll sync reads line positions from the laid-out text. A picture makes
/// one line much taller and hides the rest of its block, so the anchor table has to follow that geometry.
@MainActor
@Suite(.serialized)
struct LivePreviewScrollAnchorTests {
    private static let pictureHeight: CGFloat = 400
    private static let before = (1 ... 12).map { "Paragraph \($0)" }
    private static let after = (13 ... 70).map { "Paragraph \($0)" }
    private static let lines = before + ["", "```mermaid", "graph TD; A-->B;", "```", ""] + after
    private static let text = lines.joined(separator: "\n")

    /// The 1-based line numbers where each paragraph and the block start, as `blockStartLines` gives them.
    private static let breakpoints = lines.enumerated()
        .filter { !$0.element.isEmpty && $0.element != "```" }
        .map { $0.offset + 1 }

    private static func table(_ view: MarkdownNSTextView, visible: CGFloat = 300) -> [EditorLineAnchor] {
        computeEditorLineAnchors(
            text: text,
            totalHeight: view.contentHeightExcludingScrollPastEnd,
            visibleHeight: visible,
            breakpoints: breakpoints
        ) { view.lineTop(forCharacterIndex: $0) }
    }

    private func lineStart(_ line: Int) -> Int {
        computeLineStartOffsets(text: Self.text)[line - 1]
    }

    private func withPicture(_ body: (MarkdownNSTextView) async throws -> Void) async throws {
        let saved = LivePreviewSnapshots.shared
        defer { LivePreviewSnapshots.shared = saved }
        LivePreviewSnapshots.shared = LivePreviewSnapshots(shows: [.mermaid]) { _ in
            solidImage(.red, width: 100, height: Self.pictureHeight - 8)
        }
        let (view, coordinator) = makeLivePreviewView(Self.text)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        let drawn = try await pollUntilTrue {
            view.textStorage?.attribute(.fenBlockImage, at: lineStart(14), effectiveRange: nil) != nil
        }
        #expect(drawn, "the picture never replaced the block")
        try await body(view)
    }

    @Test
    func aPictureMovesTheLinesBelowItByItsHeight() async throws {
        let (plain, _) = makeLivePreviewView(Self.text)
        let plainTop = try #require(plain.lineTop(forCharacterIndex: lineStart(18)))
        try await withPicture { view in
            let top = try #require(view.lineTop(forCharacterIndex: lineStart(18)))
            let block = try #require(view.lineTop(forCharacterIndex: lineStart(14)))
            // The block's four source lines shrink to nothing and one line grows to the picture.
            #expect(top > plainTop, "the lines below the picture sit lower")
            #expect(top - block >= Self.pictureHeight - 20, "the first line below starts after the picture")
        }
    }

    @Test
    func theAnchorTableFollowsThePictureAndStaysSorted() async throws {
        try await withPicture { view in
            let anchors = Self.table(view)
            #expect(anchors.count > 10, "one anchor per block start")
            for (earlier, later) in zip(anchors, anchors.dropFirst()) {
                #expect(
                    later.source > earlier.source && later.rendered >= earlier.rendered,
                    "the table must not fall: \(earlier) then \(later)"
                )
                // Only the last page, which can't scroll further, may share a position.
                #expect(
                    later.rendered > earlier.rendered || later.rendered == 1,
                    "a flat step before the end: \(earlier) then \(later)"
                )
            }
            // Walking from the line above the block to the line below it crosses at least the picture's height.
            let maxScroll = view.contentHeightExcludingScrollPastEnd - 300
            let above = try #require(anchors.last { $0.source <= CGFloat(12 - 1) / CGFloat(Self.lines.count) })
            let below = try #require(anchors.first { $0.source >= CGFloat(17) / CGFloat(Self.lines.count) })
            #expect((below.rendered - above.rendered) * maxScroll >= Self.pictureHeight - 20)
        }
    }

    @Test
    func aScrollPositionRoundTripsThroughTheTableWithAPicture() async throws {
        try await withPicture { view in
            let anchors = Self.table(view)
            for line in [3, 12, 18, 24] {
                let source = CGFloat(line - 1) / CGFloat(Self.lines.count)
                let rendered = interpolateEditorAnchor(anchors, from: \.source, to: \.rendered, value: source)
                let back = interpolateEditorAnchor(anchors, from: \.rendered, to: \.source, value: rendered)
                #expect(abs(back - source) < 0.001, "line \(line) came back as \(back), not \(source)")
            }
            // A scroll position inside the picture still maps to a source line at or after the block start.
            let blockTop = try #require(view.lineTop(forCharacterIndex: lineStart(14)))
            let maxScroll = view.contentHeightExcludingScrollPastEnd - 300
            let inside = interpolateEditorAnchor(
                anchors, from: \.rendered, to: \.source, value: (blockTop + Self.pictureHeight / 2) / maxScroll
            )
            #expect(inside >= CGFloat(13) / CGFloat(Self.lines.count) - 0.001)
            #expect(inside <= CGFloat(18) / CGFloat(Self.lines.count) + 0.001)
        }
    }
}
