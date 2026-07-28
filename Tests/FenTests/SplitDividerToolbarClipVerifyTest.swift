import AppKit
@testable import FenCore
import Testing

/// End-to-end verification that `SplitDividerToolbarClip` stops `HSplitView`'s private
/// `NSSplitDividerView` from painting through the toolbar into the title bar (see that file's
/// doc comment for the macOS 26 Liquid Glass root cause). Drives a real `NSWindow` with a real
/// `NSToolbar` and a real `NSSplitViewController`-backed `NSSplitView` -- `contentLayoutRect`
/// only shrinks to exclude the toolbar's safe area once AppKit has an actual toolbar attached to
/// an actual window, so a bare `NSSplitView` with no window (the pattern every other AppKit test
/// in this suite uses) can't reproduce the bug this guards against.
///
/// `.serialized`: these tests drive real `NSWindow`/`NSSplitViewController` instances and poll
/// for AppKit to asynchronously bridge dividers on the main run loop. Running them concurrently
/// with each other (swift-testing's default) or racing this suite's own tests against one another
/// starves the very run-loop ticks the polling depends on -- confirmed by `swift test --no-parallel`
/// passing cleanly every time while the default parallel run intermittently timed out under full
/// 96-suite contention.
@Suite("Split divider toolbar clip", .serialized)
struct SplitDividerToolbarClipVerifyTest {
    /// SwiftUI's own window-content hosting view is flipped (top-left origin) -- reproducing
    /// that here matters because `NSView.convert(_:from:)` behaves differently for a flipped vs.
    /// unflipped source view, which is exactly the distinction between the fixed conversion
    /// (`from: nil`, the window's own coordinate system) and the broken one it replaced
    /// (`from: contentView`, which only coincidentally agreed with `from: nil` for an unflipped
    /// view). A plain unflipped `NSView` as `contentView` would let a regression back to
    /// `from: contentView` pass this suite for the wrong reason.
    private final class FlippedContentView: NSView {
        override var isFlipped: Bool {
            true
        }
    }

    @MainActor
    private static func makeToolbarWindowWithSplitDivider() throws -> (window: NSWindow, divider: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "SplitDividerToolbarClipVerifyTest")
        window.toolbarStyle = .unified

        let splitViewController = NSSplitViewController()
        let left = NSViewController()
        left.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let right = NSViewController()
        right.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: left))
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: right))
        splitViewController.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        let flippedContentView = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        flippedContentView.addSubview(splitViewController.view)
        window.contentView = flippedContentView
        window.setContentSize(NSSize(width: 400, height: 300))
        window.orderFront(nil)

        let divider = try #require(Self.splitDivider(in: splitViewController.splitView))
        return (window, divider)
    }

    @MainActor
    private static func splitDivider(in root: NSView) -> NSView? {
        if NSStringFromClass(type(of: root)) == "NSSplitDividerView" {
            return root
        }
        for subview in root.subviews {
            if let found = splitDivider(in: subview) {
                return found
            }
        }
        return nil
    }

    @Test("A window with a toolbar shrinks contentLayoutRect below the split divider's full frame")
    @MainActor
    func toolbarShrinksContentLayoutRectBelowDividerFrame() throws {
        let (window, divider) = try Self.makeToolbarWindowWithSplitDivider()
        // This is the bug's precondition, not the fix -- if a future AppKit stops extending
        // NSSplitView/its divider above contentLayoutRect, this test should fail loudly instead
        // of the fix's own test passing for the wrong reason.
        #expect(window.contentLayoutRect.height < divider.bounds.height)
    }

    @Test("apply masks the divider to exactly contentLayoutRect, excluding the toolbar band")
    @MainActor
    func applyExcludesOnlyTheToolbarBand() throws {
        let (window, divider) = try Self.makeToolbarWindowWithSplitDivider()
        let probe = SplitDividerToolbarClip.ProbeView()
        window.contentView?.addSubview(probe)
        probe.apply()

        let mask = try #require(divider.layer?.mask)
        let visible = try #require(mask.sublayers?.first)

        let expectedVisibleRect = divider.bounds.intersection(
            divider.convert(window.contentLayoutRect, from: nil)
        )
        #expect(visible.frame == expectedVisibleRect)
        // The mask must exclude some real region (the toolbar band) rather than degenerately
        // matching the divider's full bounds, or this test would pass even if apply did nothing.
        #expect(visible.frame.height < divider.bounds.height)
        #expect(visible.frame.height > 0)
    }

    struct OuterSplitFixture {
        let window: NSWindow
        let outerSplitViewController: NSSplitViewController
        let contentView: NSView
    }

    /// Builds only the outer split, leaving the inner one to be added later by the test -- this
    /// staging matters for reproducing the regression below, since `apply` needs to observe
    /// the outer divider before the inner one exists.
    @MainActor
    private static func makeToolbarWindowWithOuterSplitDivider() -> OuterSplitFixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "SplitDividerToolbarClipVerifyTest.nested")
        window.toolbarStyle = .unified

        let outerSplitViewController = NSSplitViewController()
        let sidebar = NSViewController()
        sidebar.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        outerSplitViewController.addSplitViewItem(NSSplitViewItem(viewController: sidebar))
        outerSplitViewController.addSplitViewItem(NSSplitViewItem(viewController: content))
        outerSplitViewController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)

        let flippedContentView = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        flippedContentView.addSubview(outerSplitViewController.view)
        window.contentView = flippedContentView
        window.setContentSize(NSSize(width: 600, height: 300))
        window.orderFront(nil)

        return OuterSplitFixture(
            window: window,
            outerSplitViewController: outerSplitViewController,
            contentView: content.view
        )
    }

    /// Fen actually nests two independent `HSplitView`s at once (outline sidebar vs. content, and
    /// inside that, editor vs. preview) -- each bridges from SwiftUI to its own `NSSplitView`
    /// asynchronously, not necessarily on the same run-loop tick. `ProbeView`'s poll loop used to
    /// stop as soon as it observed its first divider, so whichever split bridged second (after the
    /// first was already found) never got a frame-change observer or an initial mask -- this is
    /// the divider-toolbar-bleed regression a user found in the outline sidebar even after the
    /// editor/preview divider was already fixed. Reproduces the *timing*, not just the nesting: the
    /// inner split's `NSSplitViewController` is only installed into the content pane one run-loop
    /// tick after the outer one, on purpose, so the outer divider already exists and gets observed
    /// on `apply`'s first call -- exactly the scenario where the original code's `guard
    /// observedDividers.isEmpty else { return }` stopped polling before the inner divider existed.
    @Test("apply masks every divider across two nested splits, not just the first one found")
    @MainActor
    func applyMasksAllDividersAcrossNestedSplits() async throws {
        let fixture = Self.makeToolbarWindowWithOuterSplitDivider()
        let window = fixture.window
        let outerSplitViewController = fixture.outerSplitViewController
        let contentPane = fixture.contentView
        let probe = SplitDividerToolbarClip.ProbeView()
        window.contentView?.addSubview(probe)
        probe.viewDidMoveToWindow()

        let outerDivider = try #require(Self.splitDivider(in: outerSplitViewController.splitView))
        // A generous timeout, not the 5-second default -- under full-suite parallel execution
        // (96 suites, many driving their own real NSWindow), this poll competes for main-actor
        // run-loop turns with everything else, and shorter timeouts that are ample in isolation
        // were observed to time out under that contention. Asserting the result here (rather than
        // discarding it with `_ =`) matters too: a silently-timed-out poll would otherwise only
        // surface as a confusing failure several lines later, at the mask `#require` below.
        let outerMasked = try await pollUntilTrue(timeout: .seconds(15)) { outerDivider.layer?.mask != nil }
        #expect(outerMasked, "outer divider should be masked before the inner split is added")

        let innerSplitViewController = NSSplitViewController()
        let innerLeft = NSViewController()
        innerLeft.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let innerRight = NSViewController()
        innerRight.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        innerSplitViewController.addSplitViewItem(NSSplitViewItem(viewController: innerLeft))
        innerSplitViewController.addSplitViewItem(NSSplitViewItem(viewController: innerRight))
        innerSplitViewController.view.frame = contentPane.bounds
        contentPane.addSubview(innerSplitViewController.view)

        let innerDivider = try #require(Self.splitDivider(in: innerSplitViewController.splitView))
        let innerMasked = try await pollUntilTrue(timeout: .seconds(15)) { innerDivider.layer?.mask != nil }
        #expect(innerMasked, "inner divider should be masked once the poll observes it")

        for divider in [outerDivider, innerDivider] {
            let mask = try #require(
                divider.layer?.mask,
                "expected every divider to be masked, not just the first found"
            )
            let visible = try #require(mask.sublayers?.first)
            #expect(visible.frame.height > 0)
            #expect(visible.frame.height < divider.bounds.height)
        }
    }

    /// The actual bug a user hit: the outline sidebar's `HSplitView` doesn't exist at launch
    /// (`isOutlineVisible` starts `false`), so `viewDidMoveToWindow`'s first scan settles on just
    /// the editor/preview divider. Only later, when the user toggles the sidebar open, does its
    /// `NSSplitView`/`NSSplitDividerView` get created -- and that toggle was observed to bridge in
    /// with neither a fresh `viewDidMoveToWindow` nor a reliable `updateNSView` call. If nothing
    /// ever rescanned again after the first settle, that divider would stay permanently unclipped
    /// even though the first one stayed fixed. This drives that exact sequence: let the initial
    /// scan see zero dividers, *then* install a split well after `rescanNow()` (the `updateNSView`
    /// fast path) already ran and found nothing, proving the background rescan timer -- not the
    /// fast path -- is what actually catches a divider that appears later.
    @Test("A divider that appears after the initial scan has already settled still gets clipped")
    @MainActor
    func laterDividerAfterInitialScanSettledStillGetsClipped() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "SplitDividerToolbarClipVerifyTest.later")
        window.toolbarStyle = .unified

        let flippedContentView = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = flippedContentView
        window.setContentSize(NSSize(width: 400, height: 300))
        window.orderFront(nil)

        let probe = SplitDividerToolbarClip.ProbeView()
        window.contentView?.addSubview(probe)
        probe.viewDidMoveToWindow()

        // No `NSSplitView` exists yet, so the initial scan can only settle on a count of zero --
        // wait long enough for it to have run and moved on before anything is added.
        try await Task.sleep(for: .milliseconds(200))

        // Simulates SwiftUI calling `updateNSView` (e.g. in response to `isOutlineVisible`
        // flipping to `true`) at the instant *before* the newly-visible `HSplitView` has bridged
        // to a real `NSSplitView`/`NSSplitDividerView` -- exactly the ordering SwiftUI uses, since
        // `updateNSView` fires synchronously off state changes while AppKit bridging is
        // asynchronous. `NSSplitViewController` (unlike SwiftUI's `HSplitView`) creates its
        // divider synchronously, so the divider is deliberately added only *after* this call, not
        // before -- adding it first would let a single synchronous `rescanNow()` find it by
        // accident regardless of whether the background rescan timer is what actually catches it.
        probe.rescanNow()

        let splitViewController = NSSplitViewController()
        let left = NSViewController()
        left.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let right = NSViewController()
        right.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: left))
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: right))
        splitViewController.view.frame = flippedContentView.bounds
        flippedContentView.addSubview(splitViewController.view)

        let divider = try #require(Self.splitDivider(in: splitViewController.splitView))
        let masked = try await pollUntilTrue(timeout: .seconds(15)) { divider.layer?.mask != nil }
        #expect(masked, "a divider created after the initial scan settled should still get clipped")
    }

    /// The follow-on bug found once the divider hairline was fixed: the outline sidebar itself
    /// (a SwiftUI `List(...).listStyle(.sidebar)`, backed by a real `NSScrollView`) still visibly
    /// bled its rows into the toolbar, because its `NSScrollView` inherits the exact same
    /// toolbar-overflowing frame as the divider, and nothing was clipping it. Reproduces that with
    /// a real `NSScrollView` in a toolbar window, the same fixture pattern proven above for
    /// dividers, confirming `apply` extends the same layer-mask technique to scroll views too.
    @Test("apply masks a sidebar-style NSScrollView to exclude the toolbar band, like a divider")
    @MainActor
    func applyExcludesToolbarBandFromScrollView() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "SplitDividerToolbarClipVerifyTest.scrollView")
        window.toolbarStyle = .unified

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let flippedContentView = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        flippedContentView.addSubview(scrollView)
        window.contentView = flippedContentView
        window.setContentSize(NSSize(width: 400, height: 300))
        window.orderFront(nil)

        // Same precondition as the divider test: a toolbar-bearing window's contentLayoutRect
        // must actually shrink below the scroll view's full frame, or this test would pass
        // whether or not apply does anything real.
        #expect(window.contentLayoutRect.height < scrollView.bounds.height)

        let probe = SplitDividerToolbarClip.ProbeView()
        window.contentView?.addSubview(probe)
        probe.apply()

        let mask = try #require(scrollView.layer?.mask)
        let visible = try #require(mask.sublayers?.first)
        let expectedVisibleRect = scrollView.bounds.intersection(
            scrollView.convert(window.contentLayoutRect, from: nil)
        )
        #expect(visible.frame == expectedVisibleRect)
        #expect(visible.frame.height < scrollView.bounds.height)
        #expect(visible.frame.height > 0)
    }

    @Test("apply leaves the divider unmasked while its geometry is still zero-sized")
    @MainActor
    func applySkipsDegenerateGeometry() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let divider = NSView()
        window.contentView = NSView()
        window.contentView?.addSubview(divider)

        let probe = SplitDividerToolbarClip.ProbeView()
        window.contentView?.addSubview(probe)
        // No real NSSplitDividerView exists here, so apply finds nothing to mask -- this proves
        // apply doesn't crash or mask a bogus zero-size view when splitDividers(in:) comes back
        // empty, exercising the same early-exit path degenerate divider geometry takes inside
        // clip(_:to:).
        probe.apply()
        #expect(divider.layer?.mask == nil)
    }
}
