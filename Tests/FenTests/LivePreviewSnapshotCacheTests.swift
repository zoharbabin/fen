import AppKit
@testable import FenCore
import Foundation
import Testing

/// Issue #135, phase 3: the picture cache behind rendered blocks.
@MainActor
struct LivePreviewSnapshotCacheTests {
    private func key(_ source: String = "a", width: Int = 400) -> LivePreviewSnapshots.Key {
        .init(kind: .mermaid, source: source, width: width, dark: false)
    }

    @Test func rendersOnceAndCaches() async throws {
        var calls = 0
        let snapshots = LivePreviewSnapshots { _ in
            calls += 1
            return solidImage(.red, width: 100, height: 50)
        }
        let owner = NSObject()
        var ready = 0
        snapshots.request(key(), owner: owner) { ready += 1 }
        snapshots.request(key(), owner: owner) { ready += 1 }
        let done = try await pollUntilTrue { snapshots.image(for: key()) != nil }
        #expect(done)
        #expect(calls == 1)
        #expect(ready == 1, "Asking again as the same owner replaces the callback")
        snapshots.request(key(), owner: owner) { ready += 1 }
        #expect(calls == 1, "A cached key is never rendered again")
    }

    @Test func eachOwnerGetsItsCallback() async throws {
        let snapshots = LivePreviewSnapshots { _ in solidImage(.red, width: 10, height: 10) }
        let (first, second) = (NSObject(), NSObject())
        var ready: [String] = []
        snapshots.request(key(), owner: first) { ready.append("first") }
        snapshots.request(key(), owner: second) { ready.append("second") }
        _ = try await pollUntilTrue { ready.count == 2 }
        #expect(Set(ready) == ["first", "second"])
    }

    @Test func aFailureIsRememberedAndNotRetried() async throws {
        var calls = 0
        let snapshots = LivePreviewSnapshots { _ in
            calls += 1
            return nil
        }
        let owner = NSObject()
        var ready = 0
        snapshots.request(key(), owner: owner) { ready += 1 }
        let failed = try await pollUntilTrue { snapshots.hasFailed(key()) }
        #expect(failed)
        snapshots.request(key(), owner: owner) { ready += 1 }
        #expect(calls == 1)
        #expect(ready == 0)
        #expect(snapshots.image(for: key()) == nil)
    }

    @Test func aFailureIsTriedAgainAfterTheWait() async throws {
        var calls = 0
        let snapshots = LivePreviewSnapshots(retryAfter: .zero, kinds: { [] }, render: { _ in
            calls += 1
            return calls == 1 ? nil : solidImage(.red, width: 10, height: 10)
        } as @MainActor (LivePreviewSnapshots.Key) async -> PlatformImage?)
        let owner = NSObject()
        snapshots.request(key(), owner: owner) {}
        let first = try await pollUntilTrue { calls == 1 && !snapshots.hasFailed(key()) }
        #expect(first, "A failure past the wait no longer counts")
        snapshots.request(key(), owner: owner) {}
        let second = try await pollUntilTrue { snapshots.image(for: key()) != nil }
        #expect(second)
        #expect(calls == 2)
    }

    @Test func rendersOneAtATime() async throws {
        var running = 0
        var most = 0
        var finished = 0
        let owner = NSObject()
        let snapshots = LivePreviewSnapshots { _ in
            running += 1
            most = max(most, running)
            try? await Task.sleep(for: .milliseconds(20)) // stands in for render time, not a wait on the result
            running -= 1
            finished += 1
            return solidImage(.red, width: 10, height: 10)
        }
        for index in 0 ..< 4 {
            snapshots.request(key("s\(index)"), owner: owner) {}
        }
        _ = try await pollUntilTrue { finished == 4 }
        #expect(most == 1)
    }

    @Test func theOldestPictureLeavesFirst() async throws {
        let snapshots = LivePreviewSnapshots(limit: 2) { _ in solidImage(.red, width: 10, height: 10) }
        let owner = NSObject()
        for name in ["a", "b"] {
            snapshots.request(key(name), owner: owner) {}
            _ = try await pollUntilTrue { snapshots.image(for: key(name)) != nil }
        }
        #expect(snapshots.image(for: key("a")) != nil) // "a" is now the newest
        snapshots.request(key("c"), owner: owner) {}
        _ = try await pollUntilTrue { snapshots.image(for: key("c")) != nil }
        #expect(snapshots.image(for: key("b")) == nil)
        #expect(snapshots.image(for: key("a")) != nil)
    }

    @Test func widthStepsAndAppearanceMakeNewKeys() throws {
        let block = RenderedBlock(kind: .mermaid, range: NSRange(location: 0, length: 4), source: "x")
        let light = try #require(LivePreviewSnapshots.key(for: block, columnWidth: 459, background: .white))
        let wider = try #require(LivePreviewSnapshots.key(for: block, columnWidth: 479, background: .white))
        let next = try #require(LivePreviewSnapshots.key(for: block, columnWidth: 481, background: .white))
        let dark = try #require(LivePreviewSnapshots.key(for: block, columnWidth: 459, background: .black))
        #expect(light == wider)
        #expect(light.width == 440 && next.width == 480)
        #expect(light != dark && dark.dark)
        let huge = RenderedBlock(
            kind: .math, range: block.range, source: String(
                repeating: "x",
                count: LivePreviewSnapshots.maxSourceLength + 1
            )
        )
        #expect(LivePreviewSnapshots.key(for: huge, columnWidth: 400, background: .white) == nil)
    }
}

func solidImage(_ color: NSColor, width: CGFloat, height: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        color.setFill()
        rect.fill()
        return true
    }
}

extension LivePreviewSnapshots {
    /// A cache with a stub renderer, for tests that don't need WebKit.
    convenience init(
        limit: Int = 32, shows kinds: Set<RenderedBlock.Kind> = [],
        stub: @escaping @MainActor (Key) async -> NSImage?
    ) {
        self.init(limit: limit, kinds: { kinds }, render: stub)
    }
}
