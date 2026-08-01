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
    @MainActor
    final class RenderState {
        private let sanitizer = HTMLSanitizer()
        private let renderer = MarkdownRenderer()
        private var generation = 0
        private(set) var renderedHTML = ""

        /// Mirrors `SplitEditorView.renderMarkdown()`'s structure exactly: increment and capture
        /// `generation` before the async sanitize call, only assign `renderedHTML` if that
        /// generation is still current once the call resolves. `artificialDelay` stands in for
        /// whatever real-world timing (WKWebView scheduling, JS execution) determines which of
        /// two overlapping sanitize calls resolves first -- it lets this test deterministically
        /// force render A to resolve after render B, the exact ordering issue #118 flagged as a
        /// risk, rather than depending on incidental real-world timing to reproduce it.
        func render(markdown: String, artificialDelay: Duration = .zero) async {
            generation += 1
            let thisGeneration = generation

            let result = renderer.render(markdown, options: {
                var opts = MarkdownRenderer.Options()
                opts.sanitizeRawHTML = true
                return opts
            }())

            if artificialDelay > .zero {
                try? await Task.sleep(for: artificialDelay)
            }
            let sanitized = await sanitizer.sanitize(result.html)

            guard thisGeneration == generation else { return }
            renderedHTML = sanitized
        }
    }

    @Test @MainActor
    func aSupersededRenderNeverOverwritesTheLatestRendersResult() async throws {
        let state = RenderState()

        async let first: Void = state.render(
            markdown: "<kbd>stale render A</kbd>",
            artificialDelay: .milliseconds(200)
        )
        // Simulates the next keystroke arriving well inside render A's artificial delay, exactly
        // as a real burst of typing would while A's sanitize call is still in flight.
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = state.render(markdown: "<kbd>latest render B</kbd>")

        _ = await (first, second)

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
