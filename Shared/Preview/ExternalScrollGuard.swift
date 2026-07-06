import Foundation

/// Scroll-feedback-loop prevention shared by macOS's and iOS's `PreviewWebView.Coordinator`.
///
/// A scroll-fraction assignment coming from `ScrollSync` (external) and one reported by the
/// user's own scrolling (internal) must never be confused with each other, or the preview and
/// `ScrollSync` end up feeding a self-triggered scroll back into each other, compounding drift.
/// `isApplyingExternalScroll` is the gate: set for the duration of every external assignment,
/// checked before forwarding any observed scroll back up through `onScrollChange`.
///
/// `generation` exists because the gate is cleared from an async completion handler
/// (`evaluateJavaScript`'s callback) that can be outrun by a newer assignment starting before
/// an older one's callback fires — `endExternalScroll` only clears the gate if its token still
/// matches the latest `beginExternalScroll` call, so a stale completion can't clobber a newer
/// assignment still in flight. See `docs/ARCHITECTURE.md`'s note on `PreviewWebView`'s
/// `scrollAssignmentJS` for the matching JS-side half of this same race.
final class ExternalScrollGuard {
    private(set) var isApplyingExternalScroll = false
    private(set) var lastAppliedScrollFraction: CGFloat?
    private(set) var hasScrolledSinceLoad = false
    private var generation = 0

    /// Call when a fresh document is about to load, before any scroll-restore happens.
    func reset() {
        hasScrolledSinceLoad = false
    }

    /// Whether `fraction` differs enough from the last applied one to be worth re-applying —
    /// skips redundant work and avoids re-triggering the guard for a no-op assignment.
    func shouldApply(_ fraction: CGFloat) -> Bool {
        lastAppliedScrollFraction == nil || abs(fraction - lastAppliedScrollFraction!) > 0.001
    }

    /// Forces the next `shouldApply` to report true — used when a load-time restore raced with
    /// a later external assignment and the stale pre-load snapshot shouldn't suppress a re-apply.
    func clearLastApplied() {
        lastAppliedScrollFraction = nil
    }

    /// Records the target of an external assignment that's about to start, before any async
    /// work begins — so a second assignment racing the first's completion handler sees this
    /// update immediately rather than only after that handler resolves. `countsAsSinceLoad`
    /// is false only for the load-time scroll *restore* itself — `hasScrolledSinceLoad` exists
    /// to detect a real external scroll racing the load, not the restore reacting to it.
    func recordPendingScroll(_ fraction: CGFloat, countsAsSinceLoad: Bool = true) {
        if countsAsSinceLoad { hasScrolledSinceLoad = true }
        lastAppliedScrollFraction = fraction
    }

    /// Opens the gate for the span of a single external scroll write (e.g. one
    /// `evaluateJavaScript` round trip or one `setContentOffset` call). Returns a token; pass
    /// it to `endExternalScroll` so a stale completion handler can't clear a newer assignment's
    /// gate early — momentum scrolling can start a second assignment before the first's
    /// completion handler fires.
    func beginExternalScroll() -> Int {
        isApplyingExternalScroll = true
        generation += 1
        return generation
    }

    /// Clears the gate only if `token` still matches the latest `beginExternalScroll` call.
    func endExternalScroll(token: Int) {
        guard token == generation else { return }
        isApplyingExternalScroll = false
    }

    /// Records a scroll fraction reported by the observer (user-driven, not an assignment
    /// echo). Call only after confirming `isApplyingExternalScroll` is false.
    func recordIncomingScroll(_ fraction: CGFloat) {
        lastAppliedScrollFraction = fraction
    }
}
