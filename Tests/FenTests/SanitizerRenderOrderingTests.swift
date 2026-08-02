@testable import FenCore
import Foundation
import Testing

/// Proves issue #118 rule 1.2: a render superseded by a newer keystroke while its async
/// DOMPurify sanitize pass is still in flight must never overwrite the latest render's result.
/// `SplitEditorView.renderMarkdown()`'s `renderGeneration` counter is `private` to that SwiftUI
/// `View` struct and can't be invoked directly from a test (same constraint `PreviewFlickerVerifyTest`
/// and `PreviewScrollRaceVerifyTest` work around), so this test reconstructs the exact same
/// generation-guard structure `SplitEditorView.swift:525-558` uses -- capture the generation
/// before the sanitize `await`, only assign the result if that generation is still current when
/// it resolves -- driving a real `HTMLSanitizer` against real Markdown so the guard is proven
/// against genuine async timing, not a synchronous stand-in.
struct SanitizerRenderOrderingTests {
    /// Suspends a render at the exact point where it would otherwise await the sanitizer, and
    /// lets the test resume it deterministically -- this repo forbids fixed-duration sleeps as a
    /// synchronization mechanism (see CONTRIBUTING.md#tests), so ordering is proven with a real
    /// handshake instead of racing a `Task.sleep` against incidental timing.
    @MainActor
    final class RenderGate {
        private var openContinuation: CheckedContinuation<Void, Never>?
        private var arrivedContinuation: CheckedContinuation<Void, Never>?
        private var hasArrived = false
        private var isOpen = false

        /// Called by the render this gate blocks: records that it reached the gate, then
        /// suspends until `open()` is called (or returns immediately if already open).
        func wait() async {
            hasArrived = true
            arrivedContinuation?.resume()
            arrivedContinuation = nil
            if isOpen {
                return
            }
            await withCheckedContinuation { continuation in
                self.openContinuation = continuation
            }
        }

        /// Called by the test: resumes once the blocked render has actually reached `wait()`,
        /// so the test never has to guess how long that takes.
        func waitUntilArrived() async {
            if hasArrived {
                return
            }
            await withCheckedContinuation { continuation in
                self.arrivedContinuation = continuation
            }
        }

        func open() {
            isOpen = true
            openContinuation?.resume()
            openContinuation = nil
        }
    }

    @MainActor
    final class RenderState {
        private let sanitizer = HTMLSanitizer()
        private let renderer = MarkdownRenderer()
        private var generation = 0
        private(set) var renderedHTML = ""

        /// Mirrors `SplitEditorView.renderMarkdown()`'s structure exactly: increment and capture
        /// `generation` before the async sanitize call, only assign `renderedHTML` if that
        /// generation is still current once the call resolves. `gate`, when given, blocks this
        /// render immediately before the sanitize call until the test releases it -- standing in
        /// for whatever real-world timing (WKWebView scheduling, JS execution) would otherwise
        /// determine which of two overlapping sanitize calls resolves first.
        func render(markdown: String, gate: RenderGate? = nil) async {
            generation += 1
            let thisGeneration = generation

            let result = renderer.render(markdown, options: {
                var opts = MarkdownRenderer.Options()
                opts.sanitizeRawHTML = true
                return opts
            }())

            await gate?.wait()
            let sanitized = await sanitizer.sanitize(result.html)

            guard thisGeneration == generation else { return }
            renderedHTML = sanitized
        }
    }

    @Test @MainActor
    func aSupersededRenderNeverOverwritesTheLatestRendersResult() async {
        let state = RenderState()
        let gateA = RenderGate()

        async let first: Void = state.render(markdown: "<kbd>stale render A</kbd>", gate: gateA)

        // Deterministically wait until render A is blocked just before its sanitize call --
        // `waitUntilArrived()` only resumes once A's `gate.wait()` actually runs, no sleep needed.
        await gateA.waitUntilArrived()

        // Let render B start and fully complete while A is still held at the gate -- this is the
        // exact scenario rule 1.2 guards against: an older render resolving after a newer one.
        await state.render(markdown: "<kbd>latest render B</kbd>")

        // Now release A: it resumes, sanitizes, and finds its captured generation stale.
        gateA.open()
        _ = await first

        #expect(
            state.renderedHTML.contains("latest render B"),
            "the later render's result must be what's shown"
        )
        #expect(
            !state.renderedHTML.contains("stale render A"),
            "a render superseded by a newer keystroke must never overwrite renderedHTML once it belatedly resolves"
        )
    }

    @Test @MainActor
    func whenNoRenderIsSupersededBothCompleteNormally() async {
        let state = RenderState()

        await state.render(markdown: "<kbd>first</kbd>")
        #expect(state.renderedHTML.contains("first"))

        await state.render(markdown: "<kbd>second</kbd>")
        #expect(state.renderedHTML.contains("second"))
        #expect(
            !state.renderedHTML.contains("first"),
            "a completed, non-superseded render still replaces the prior one"
        )
    }
}
