import AppKit
@testable import FenCore
import Foundation
import Testing

/// Issue #135, phase 4: pictures follow the width, and an older picture stands in while a new one renders.
@MainActor
@Suite(.serialized)
struct LivePreviewResizeTests {
    private static let text = "Intro\n\n```mermaid\ngraph TD; A-->B;\n```\n\nTail"
    private static let blockStart = ("Intro\n\n" as NSString).length

    /// A stub that draws a picture a quarter as wide as the key, and counts the widths it was asked for.
    private final class Renders {
        var widths: [Int] = []
    }

    private func withStub(_ body: (Renders) async throws -> Void) async throws {
        let saved = LivePreviewSnapshots.shared
        defer { LivePreviewSnapshots.shared = saved }
        let renders = Renders()
        LivePreviewSnapshots.shared = LivePreviewSnapshots(shows: [.mermaid]) { key in
            renders.widths.append(key.width)
            return solidImage(.red, width: CGFloat(key.width / 4), height: 60)
        }
        try await body(renders)
    }

    private func picture(_ view: MarkdownNSTextView) -> NSImage? {
        view.textStorage?.attribute(.fenBlockImage, at: Self.blockStart, effectiveRange: nil) as? NSImage
    }

    private func resize(_ view: MarkdownNSTextView, to width: CGFloat) {
        view.textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    @Test
    func aResizeDrawsThePictureAgainAtTheNewWidthWithoutShowingTheSource() async throws {
        try await withStub { renders in
            let (view, coordinator) = makeLivePreviewView(Self.text)
            view.setSelectedRange(NSRange(location: (Self.text as NSString).length, length: 0))
            coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
            _ = try await pollUntilTrue { picture(view)?.size.width == 90 }
            #expect(renders.widths == [360])

            resize(view, to: 800)
            #expect(picture(view) != nil, "The older picture stands in, so the source never flashes")
            let redrawn = try await pollUntilTrue { picture(view)?.size.width == 190 }
            #expect(redrawn, "The picture is rendered again for the wider column")
            #expect(renders.widths == [360, 760])
        }
    }

    @Test
    func aSmallResizeKeepsThePicture() async throws {
        try await withStub { renders in
            let (view, coordinator) = makeLivePreviewView(Self.text)
            view.setSelectedRange(NSRange(location: (Self.text as NSString).length, length: 0))
            coordinator.applyLivePreviewStylingIfNeeded(in: view, fullDocument: true)
            _ = try await pollUntilTrue { picture(view) != nil }
            resize(view, to: 410)
            #expect(renders.widths == [360], "Ten points is inside the same width step")
        }
    }

    @Test
    func aNarrowerColumnScalesThePictureKeepingItsShape() {
        let wide = solidImage(.red, width: 400, height: 200)
        #expect(LivePreviewBlockStyle.displaySize(of: wide, column: 800) == CGSize(width: 400, height: 200))
        #expect(LivePreviewBlockStyle.displaySize(of: wide, column: 200) == CGSize(width: 200, height: 100))
    }

    @Test
    func theLineIsAsTallAsThePictureIsDrawn() async throws {
        try await withStub { _ in
            let (view, coordinator) = makeLivePreviewView(Self.text, width: 400)
            let storage = try #require(view.textStorage)
            let block = RenderedBlock(
                kind: .mermaid,
                range: NSRange(location: Self.blockStart, length: 30),
                source: "x"
            )
            let image = solidImage(.red, width: 400, height: 200)
            LivePreviewBlockStyle.applyRendered(
                image, block: block.range, storage: storage, background: .white, column: 100
            )
            let style = try #require(
                storage.attribute(.paragraphStyle, at: Self.blockStart, effectiveRange: nil) as? NSParagraphStyle
            )
            #expect(style.minimumLineHeight == 50 + 2 * LivePreviewBlockStyle.pictureMargin)
            _ = coordinator
        }
    }

    @Test
    func aStandInIsTheSameBlockAndAppearance() async throws {
        let snapshots = LivePreviewSnapshots(shows: [.mermaid]) { _ in solidImage(.red, width: 10, height: 10) }
        let owner = NSObject()
        let cached = LivePreviewSnapshots.Key(kind: .mermaid, source: "a", width: 360, dark: false)
        snapshots.request(cached, owner: owner) {}
        _ = try await pollUntilTrue { snapshots.image(for: cached) != nil }
        #expect(snapshots.standIn(for: .init(kind: .mermaid, source: "a", width: 760, dark: false)) != nil)
        #expect(snapshots.standIn(for: .init(kind: .mermaid, source: "b", width: 760, dark: false)) == nil)
        #expect(snapshots.standIn(for: .init(kind: .mermaid, source: "a", width: 760, dark: true)) == nil)
        #expect(snapshots.standIn(for: .init(kind: .math, source: "a", width: 760, dark: false)) == nil)
    }

    @Test
    func aNewStyleOrCustomCSSMakesANewKey() throws {
        let suite = "livepreview.look.\(UUID().uuidString)"
        let prefs = try Preferences(defaults: #require(UserDefaults(suiteName: suite)))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let block = RenderedBlock(kind: .mermaid, range: NSRange(location: 0, length: 4), source: "x")
        func key() throws -> LivePreviewSnapshots.Key {
            try #require(LivePreviewSnapshots.key(for: block, columnWidth: 400, background: .white, preferences: prefs))
        }
        let before = try key()
        prefs.htmlStyleName = "Clearness"
        let styled = try key()
        #expect(before != styled)
        prefs.customCSSEnabled = true
        prefs.customCSS = "body { color: red }"
        #expect(try key() != styled)
        prefs.customCSSEnabled = false
        #expect(try key() == styled, "Custom CSS that is off changes nothing")
    }
}
