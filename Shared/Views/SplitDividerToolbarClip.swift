#if os(macOS)
    import AppKit
    import SwiftUI

    /// Stops every private `NSSplitDividerView` and the outline sidebar's `NSScrollView` from
    /// painting through the window's toolbar into the title bar.
    ///
    /// macOS 26's Liquid Glass window chrome has `HSplitView`'s underlying `NSSplitView`
    /// deliberately extend its own frame up into the toolbar's safe area (WWDC25 session 310:
    /// "NSSplitView will extend that item's frame beneath the sidebar and then apply a safe area
    /// layout guide"). Each pane's own content already insets itself below the toolbar to honor
    /// that guide in the common case, but two things never get that treatment: the divider itself
    /// (drawn across its full, still-extended frame, straight through the toolbar), and the
    /// outline sidebar's `List(...).listStyle(.sidebar)`, whose `NSScrollView` inherits the same
    /// overflowing frame with nothing clipping its rows to below the toolbar.
    /// `automaticallyAdjustsContentInsets` tries to compensate the scroll view with a top content
    /// inset, but that only shifts where scrolling starts, not what's drawn -- rows still paint
    /// into the overflowing top band of the frame.
    ///
    /// `NSSplitView.clipsToBounds`/`NSScrollView.clipsToBounds` do nothing for this: each view's
    /// own *bounds* already include the toolbar overlap (that's the mechanism above), so clipping
    /// a view to its own bounds removes nothing -- confirmed by dumping Fen's real view tree,
    /// where both frames already exceed `NSWindow.contentLayoutRect`'s by exactly the overlap
    /// amount. The overhang has to be clipped against `contentLayoutRect` itself, on each view.
    /// Both `NSSplitDividerView` and `NSScrollView` are safe to layer-mask directly (never an
    /// ancestor) -- the blank-screen regression from an earlier attempt came from `wantsLayer =
    /// true` on an ancestor of `WKWebView`/`NSScrollView`, not from layer-backing in general, and
    /// neither target here is an ancestor of a `WKWebView`.
    struct SplitDividerToolbarClip: NSViewRepresentable {
        func makeNSView(context _: Context) -> NSView {
            ProbeView()
        }

        /// Kept as a fast-path hint for whenever SwiftUI calls this on a real update -- `apply()`
        /// is idempotent, so this costs nothing extra even if the timer-based rescan below would
        /// have caught the same change shortly after.
        func updateNSView(_ view: NSView, context _: Context) {
            (view as? ProbeView)?.rescanNow()
        }

        final class ProbeView: NSView {
            /// Views already wired up with a frame-change observer, keyed by identity -- without
            /// this, every rescan would pile a duplicate observer onto the same still-alive view.
            private var observedViews = Set<ObjectIdentifier>()
            /// Neither `viewDidMoveToWindow` nor SwiftUI's `updateNSView` can be trusted to fire
            /// when a new `NSSplitView`/`NSSplitDividerView` or sidebar `NSScrollView` subtree
            /// bridges in -- toggling the outline sidebar was observed to bridge a new divider and
            /// scroll view into the real view hierarchy with neither callback firing again. A
            /// callback-driven rescan is fundamentally unreliable here, so this timer rescans on a
            /// fixed cadence instead, for as long as this view is in a window -- `apply()` is
            /// idempotent (it only masks/observes views it hasn't already), so a tick that finds
            /// nothing new is nearly free.
            private nonisolated(unsafe) var rescanTimer: Timer?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window != nil {
                    startRescanning()
                } else {
                    stopRescanning()
                }
            }

            func rescanNow() {
                apply()
            }

            deinit {
                rescanTimer?.invalidate()
            }

            private func startRescanning() {
                stopRescanning()
                apply()
                let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.apply()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                rescanTimer = timer
            }

            private func stopRescanning() {
                rescanTimer?.invalidate()
                rescanTimer = nil
            }

            func apply() {
                guard let window, let contentView = window.contentView else { return }
                for divider in Self.splitDividers(in: contentView) {
                    clip(divider, to: window)
                    observe(divider, window: window)
                }
                for scrollView in Self.scrollViews(in: contentView) {
                    clip(scrollView, to: window)
                    observe(scrollView, window: window)
                }
            }

            private func clip(_ view: NSView, to window: NSWindow) {
                // `window.contentLayoutRect` is already expressed in the window's own base
                // coordinate system (bottom-left origin) -- passing `from: contentView` instead of
                // `from: nil` is a documented-behavior mismatch whenever `contentView` is itself
                // flipped (SwiftUI's hosting view is), which silently offset the mask by the
                // toolbar's height and made it clip nothing real.
                let safeAreaRect = view.convert(window.contentLayoutRect, from: nil)
                let visibleRect = view.bounds.intersection(safeAreaRect)
                // A zero-size rect means the view's geometry hasn't settled yet (e.g. the very
                // first layout pass, before `NSSplitView.tile()` has run) -- masking to it would
                // blank the view instead of just trimming its toolbar overhang, so leave it
                // unmasked until a later call sees real geometry (the frame-change observer below
                // guarantees one follows once layout settles).
                guard visibleRect.width > 0, visibleRect.height > 0 else { return }

                view.wantsLayer = true
                let mask = CALayer()
                mask.frame = view.bounds
                let visible = CALayer()
                visible.frame = visibleRect
                visible.backgroundColor = NSColor.black.cgColor
                mask.addSublayer(visible)
                view.layer?.mask = mask
            }

            private func observe(_ view: NSView, window: NSWindow) {
                let id = ObjectIdentifier(view)
                guard !observedViews.contains(id) else { return }
                observedViews.insert(id)
                view.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self, weak view, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let view, let window else { return }
                        self.clip(view, to: window)
                    }
                }
            }

            /// `NSSplitDividerView` is private API with no public type to check against, so this
            /// matches on the class name string -- read-only introspection of a standard
            /// AppKit-managed view, not a call into private API surface.
            static func splitDividers(in root: NSView) -> [NSView] {
                root.subviews.flatMap { subview -> [NSView] in
                    let nested = splitDividers(in: subview)
                    guard NSStringFromClass(type(of: subview)) == "NSSplitDividerView" else { return nested }
                    return [subview] + nested
                }
            }

            static func scrollViews(in root: NSView) -> [NSScrollView] {
                root.subviews.flatMap { subview -> [NSScrollView] in
                    let nested = scrollViews(in: subview)
                    guard let scrollView = subview as? NSScrollView else { return nested }
                    return [scrollView] + nested
                }
            }
        }
    }
#endif
