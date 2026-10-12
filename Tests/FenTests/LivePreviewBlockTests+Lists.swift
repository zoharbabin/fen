import AppKit
@testable import FenCore
import Foundation
import Testing

/// Issue #135: unordered list markers are drawn as round bullets.
extension LivePreviewBlockRenderTests {
    @Test @MainActor
    func aDashMarkerIsHiddenAndDrawnAsABullet() throws {
        let (view, coordinator) = makeView("- item\n\nTail")
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.fenBlockDecoration, at: 0, effectiveRange: nil) as? String == "bullet")
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Self.background)
        #expect(storage.string == "- item\n\nTail", "The source text is untouched")
        // The dash is hidden, so only the drawn bullet can make this spot dark.
        let rep = try bitmap(of: view)
        let line = try fragment(view, at: 0)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let painted = (0 ..< 12).contains { x in
            let color = rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(line.midY * scale))?.usingColorSpace(.sRGB)
            return (color.map { min($0.redComponent, $0.greenComponent, $0.blueComponent) } ?? 1) < 0.9
        }
        #expect(painted)
    }

    @Test @MainActor
    func orderedAndTaskItemsKeepTheirMarker() throws {
        let (view, coordinator) = makeView("1. one\n- [ ] task\n* star\n\nTail")
        style(view, coordinator)
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.fenBlockDecoration, at: 0, effectiveRange: nil) == nil)
        let task = ("1. one\n" as NSString).length
        #expect(storage.attribute(.fenBlockDecoration, at: task, effectiveRange: nil) == nil)
        let star = ("1. one\n- [ ] task\n" as NSString).length
        #expect(storage.attribute(.fenBlockDecoration, at: star, effectiveRange: nil) as? String == "bullet")
    }

    @Test @MainActor
    func theCaretLineKeepsItsDash() throws {
        let (view, coordinator) = makeView("- item")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.fenBlockDecoration, at: 0, effectiveRange: nil) == nil)
    }
}
