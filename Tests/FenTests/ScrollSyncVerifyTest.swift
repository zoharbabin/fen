@testable import FenCore
import Foundation
import Testing
import WebKit

/// End-to-end verification that `scroll-sync.js`'s anchor table actually corrects
/// for uneven density between the source Markdown and the rendered preview, using
/// the same real-pipeline-into-a-live-WKWebView pattern as
/// `PreviewSchemeHandlerVerifyTest.swift` and `GFMFeatureCoverageTests.swift`.
@Suite("Scroll sync anchor mapping")
struct ScrollSyncVerifyTest {
    /// One long paragraph (a single source line that wraps into many rendered
    /// lines) followed by many short one-line headings makes source-line density
    /// and rendered-pixel density diverge sharply — exactly the shape of document
    /// that caused the drift reported by the user.
    private static func unevenDensityDocument() -> (markdown: String, sourceLineCount: Int) {
        var lines = [String(repeating: "word ", count: 800).trimmingCharacters(in: .whitespaces)]
        for i in 1 ... 40 {
            lines.append("")
            lines.append("## Heading \(i)")
        }
        return (lines.joined(separator: "\n"), lines.count)
    }

    @Test("Anchor table maps a block's own source position back to its rendered position")
    @MainActor
    func anchorMapsSourcePositionToRenderedPosition() async throws {
        let (markdown, sourceLineCount) = Self.unevenDensityDocument()
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            sourceLineCount: sourceLineCount
        )

        let isScrollable = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )
        #expect(isScrollable, "Expected the long paragraph to make the document taller than the viewport")

        let anchorInfo = try await webView.evaluateJavaScript("""
        (function () {
            var heading = document.querySelector('h2[data-sourcepos]');
            if (!heading) { return null; }
            var startLine = parseInt(heading.getAttribute('data-sourcepos').split(':')[0], 10);
            var sourceFraction = (startLine - 1) / window.__fenTotalSourceLines;
            var maxScroll = document.documentElement.scrollHeight - document.documentElement.clientHeight;
            var renderedFraction = (heading.getBoundingClientRect().top + window.scrollY) / maxScroll;
            return {
                sourceFraction: sourceFraction,
                renderedFraction: renderedFraction,
                mapped: window.__fenScrollSync.renderedFractionForSource(sourceFraction),
            };
        })();
        """)

        let info = try #require(anchorInfo as? [String: Double])
        let sourceFraction = try #require(info["sourceFraction"])
        let renderedFraction = try #require(info["renderedFraction"])
        let mapped = try #require(info["mapped"])

        #expect(
            abs(sourceFraction - renderedFraction) > 0.1,
            """
            Expected the oversized first paragraph to make source and rendered fractions diverge \
            (source: \(sourceFraction), rendered: \(renderedFraction)) — otherwise this document \
            doesn't actually exercise the correction
            """
        )
        #expect(
            abs(mapped - renderedFraction) < 0.02,
            """
            Expected renderedFractionForSource(sourceFraction) to recover the heading's actual \
            rendered position (got \(mapped), wanted ~\(renderedFraction))
            """
        )
    }

    @Test("Source and rendered fraction mappings round-trip")
    @MainActor
    func mappingsRoundTrip() async throws {
        let (markdown, sourceLineCount) = Self.unevenDensityDocument()
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            sourceLineCount: sourceLineCount
        )

        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )

        let roundTripped = try await webView.evaluateJavaScript("""
        window.__fenScrollSync.sourceFractionForRendered(
            window.__fenScrollSync.renderedFractionForSource(0.5)
        );
        """)

        let result = try #require(roundTripped as? Double)
        #expect(
            abs(result - 0.5) < 0.02,
            "Expected round-tripping 0.5 through both mappings to return ~0.5, got \(result)"
        )
    }

    /// cmark-gfm's `data-sourcepos` is relative to the Markdown *after* front-matter
    /// stripping, but the editor's scroll fraction is relative to the raw source it
    /// displays (front matter included). Prepending front matter here reproduces the
    /// bug where every anchor was off by exactly the front matter's line count —
    /// e.g. `assets/demo.md`'s "Tables (GFM)" heading reported `data-sourcepos` line
    /// 172 for its actual raw-source line 176, a 4-line offset matching its front matter.
    @Test("Front matter's line offset is folded into anchor source fractions")
    @MainActor
    func frontMatterOffsetFoldedIntoAnchors() async throws {
        let frontMatter = "---\ntitle: Test\nauthor: Fen\n---\n"
        let frontMatterLineCount = 4
        let (body, bodyLineCount) = Self.unevenDensityDocument()
        let markdown = frontMatter + body

        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            sourceLineCount: frontMatterLineCount + bodyLineCount
        )

        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )

        let anchorInfo = try await webView.evaluateJavaScript("""
        (function () {
            var heading = document.querySelector('h2[data-sourcepos]');
            if (!heading) { return null; }
            var strippedStartLine = parseInt(heading.getAttribute('data-sourcepos').split(':')[0], 10);
            var rawStartLine = strippedStartLine + window.__fenSourceLineOffset;
            var rawSourceFraction = (rawStartLine - 1) / window.__fenTotalSourceLines;
            var maxScroll = document.documentElement.scrollHeight - document.documentElement.clientHeight;
            var renderedFraction = (heading.getBoundingClientRect().top + window.scrollY) / maxScroll;
            return {
                rawSourceFraction: rawSourceFraction,
                renderedFraction: renderedFraction,
                mapped: window.__fenScrollSync.renderedFractionForSource(rawSourceFraction),
            };
        })();
        """)

        let info = try #require(anchorInfo as? [String: Double])
        let renderedFraction = try #require(info["renderedFraction"])
        let mapped = try #require(info["mapped"])

        #expect(
            abs(mapped - renderedFraction) < 0.02,
            """
            Expected renderedFractionForSource to recover the heading's actual rendered position \
            from its raw (front-matter-inclusive) source fraction (got \(mapped), wanted \
            ~\(renderedFraction)) — a mismatch here means the front matter's line count isn't \
            being folded into the anchor table
            """
        )
    }

    /// The anchor table used to be built once on `load` and cached forever, so any reflow
    /// afterward — the user dragging the split divider, the window resizing, an async
    /// Mermaid/MathJax render, or even a late-loading image — left every element sitting at
    /// a new rendered position while the table kept predicting from the stale one. The drift
    /// was near zero right after the anchor closest to the resize and grew the further a
    /// fraction landed past it, matching the user's report of losing sync after `[TOC]` and
    /// getting worse deeper into `assets/demo.md`.
    @Test("Anchor table recomputes after the viewport reflows, instead of predicting from a stale layout")
    @MainActor
    func anchorTableRecomputesAfterReflow() async throws {
        let (markdown, sourceLineCount) = Self.unevenDensityDocument()
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            sourceLineCount: sourceLineCount
        )

        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )

        let widthBeforeResize = try #require(
            try await webView.evaluateJavaScript("document.documentElement.clientWidth") as? Double
        )

        // Narrowing the viewport rewraps the long paragraph, changing every later
        // heading's rendered position without firing any event scroll-sync used to listen
        // for.
        webView.setFrameSize(NSSize(width: webView.frame.width - 250, height: webView.frame.height))
        // setFrameSize's effect on the JS-visible viewport lands after WKWebView's own async
        // layout pass, not synchronously with this call -- poll for document.documentElement's
        // clientWidth to actually reflect the new frame instead of guessing how long that pass
        // takes. refreshAnchorsIfStale (scroll-sync.js) rechecks layout dimensions synchronously
        // on every call, so once the width has changed, the anchor table is guaranteed fresh by
        // the time the next assertion below calls into it.
        _ = try await pollUntilTrue {
            let width = try await webView.evaluateJavaScript("document.documentElement.clientWidth") as? Double
            return width != widthBeforeResize
        }

        let anchorInfo = try await webView.evaluateJavaScript("""
        (function () {
            var heading = document.querySelector('h2[data-sourcepos]');
            if (!heading) { return null; }
            var startLine = parseInt(heading.getAttribute('data-sourcepos').split(':')[0], 10);
            var sourceFraction = (startLine - 1) / window.__fenTotalSourceLines;
            var maxScroll = document.documentElement.scrollHeight - document.documentElement.clientHeight;
            var renderedFraction = (heading.getBoundingClientRect().top + window.scrollY) / maxScroll;
            return {
                renderedFraction: renderedFraction,
                mapped: window.__fenScrollSync.renderedFractionForSource(sourceFraction),
            };
        })();
        """)

        let info = try #require(anchorInfo as? [String: Double])
        let renderedFraction = try #require(info["renderedFraction"])
        let mapped = try #require(info["mapped"])

        #expect(
            abs(mapped - renderedFraction) < 0.02,
            """
            Expected renderedFractionForSource to recover the heading's actual post-reflow \
            rendered position (got \(mapped), wanted ~\(renderedFraction)) — a mismatch means \
            the anchor table is still predicting from the pre-reflow layout
            """
        )
    }

    @Test("Falls back to identity mapping when there's no sourcepos metadata")
    @MainActor
    func identityFallbackWithoutSourcePositions() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Just a heading")

        let mapped = try await webView.evaluateJavaScript(
            "window.__fenScrollSync.renderedFractionForSource(0.5);"
        )
        #expect((mapped as? Double) == 0.5, "Expected identity fallback with no data-sourcepos anchors")
    }

    /// Issue #110: the old staleness check compared `(clientWidth, clientHeight, scrollHeight)`
    /// against a cached snapshot, which can alias -- an in-flight resize passing through an
    /// intermediate frame whose triple happens to match the previously cached one wrongly skips
    /// a rebuild. Drives the dirty flag through `window.__fenScrollSyncMarkDirty` -- the exact
    /// function `ResizeObserver`'s callback invokes -- rather than a real `setFrameSize` (whose
    /// `ResizeObserver`/`resize`-event delivery timing in a headless `WKWebView` isn't
    /// deterministic enough to assert an exact rebuild count against) to prove the new mechanism
    /// has no dimension comparison to alias against at all: a rebuild fires on the next read
    /// even when the document's dimensions haven't changed since the last one.
    @Test("Marking dirty forces a rebuild on the next read even with unchanged dimensions")
    @MainActor
    func markingDirtyForcesRebuildRegardlessOfUnchangedDimensions() async throws {
        let (markdown, sourceLineCount) = Self.unevenDensityDocument()
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            sourceLineCount: sourceLineCount
        )

        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )
        _ = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let rebuildCountAfterFirstRead = try #require(
            try await webView.evaluateJavaScript("window.__fenScrollSyncRebuildCount") as? Double
        )

        let widthBefore = try await webView.evaluateJavaScript("document.documentElement.clientWidth")
        _ = try await webView.evaluateJavaScript("window.__fenScrollSyncMarkDirty();")
        let widthAfterMarkDirty = try await webView.evaluateJavaScript("document.documentElement.clientWidth")
        #expect(
            (widthBefore as? Double) == (widthAfterMarkDirty as? Double),
            "This test's premise is an unchanged layout -- marking dirty itself must not resize anything"
        )

        _ = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let rebuildCountAfterSecondRead = try #require(
            try await webView.evaluateJavaScript("window.__fenScrollSyncRebuildCount") as? Double
        )

        #expect(
            rebuildCountAfterSecondRead > rebuildCountAfterFirstRead,
            """
            Expected a rebuild on the read following markAnchorsDirty despite unchanged \
            dimensions -- a scalar-triple comparison would wrongly treat this as unchanged, but \
            the dirty flag has no dimension value to compare against
            """
        )
    }

    /// Rule 3.1 (issue #110): a rebuild triggered by DOM mutation (simulating Mermaid/MathJax
    /// swapping placeholder content for rendered output after `window.onload`) must reflect that
    /// mutation on the very next read, never a partial/stale intermediate state.
    @Test("Anchor table reflects a DOM mutation injected after initial load, on the next read")
    @MainActor
    func anchorTableReflectsLateDOMMutation() async throws {
        let (markdown, sourceLineCount) = Self.unevenDensityDocument()
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            configurePreferences: { $0.editorShowLineNumbers = true },
            sourceLineCount: sourceLineCount
        )
        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )
        let countBefore = try #require(
            try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors().length") as? Double
        )

        // Simulates an async render (Mermaid/MathJax) inserting a new leaf sourcepos block into
        // the document well after initial load -- no resize event fires for this. Wrapped in an
        // IIFE returning undefined: appendChild's return value is a DOM Node, which
        // evaluateJavaScript can't bridge back to Swift and would fail the call.
        _ = try await webView.evaluateJavaScript("""
        (function () {
            var el = document.createElement('p');
            el.setAttribute('data-sourcepos', '1:1-1:1');
            document.body.appendChild(el);
        })();
        """)

        let countAfter = try await pollUntilTrue(timeout: .seconds(3)) {
            let count = try await webView.evaluateJavaScript(
                "window.__fenScrollSync.lineNumberAnchors().length"
            ) as? Double
            return count.map { $0 != countBefore } ?? false
        }
        #expect(countAfter, "Expected the gutter anchor count to change after a late DOM mutation")
    }

    /// Rule 3.2 (issue #110): scroll-sync.js wires Mermaid/MathJax's ready promise with
    /// `.then(markAnchorsDirty, markAnchorsDirty)` -- both arguments the same function -- so a
    /// *rejected* ready promise still dirties the table instead of leaving it permanently stale.
    /// Mermaid's own `init()` (`mermaid.init.js`) catches every per-diagram render error
    /// internally and never actually rejects `__fenMermaidReadyPromise` itself, so a genuine
    /// end-to-end rejection can't be produced through the real rendering pipeline. This drives
    /// the exact two-argument `.then` pattern scroll-sync.js uses against a promise this test
    /// rejects itself, proving the failure branch -- not just the success branch -- reaches
    /// `markAnchorsDirty`.
    @Test("A rejected ready promise still dirties the anchor table")
    @MainActor
    func rejectedReadyPromiseStillDirtiesAnchorTable() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Just a heading")

        _ = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let baseline = try #require(
            try await webView.evaluateJavaScript("window.__fenScrollSyncRebuildCount") as? Double
        )

        _ = try await webView.evaluateJavaScript("""
        (function () {
            var rejecting = Promise.reject(new Error('simulated Mermaid/MathJax render failure'));
            rejecting.then(window.__fenScrollSyncMarkDirty, window.__fenScrollSyncMarkDirty);
        })();
        """)

        let dirtiedAfterRejection = try await pollUntilTrue(timeout: .seconds(3)) {
            let widthProbe = try await webView.evaluateJavaScript("""
            (function () {
                window.__fenScrollSync.lineNumberAnchors();
                return window.__fenScrollSyncRebuildCount;
            })();
            """) as? Double
            return widthProbe.map { $0 > baseline } ?? false
        }
        #expect(dirtiedAfterRejection, "Expected a rejected ready promise to still trigger a rebuild on the next read")
    }

    /// Rule 4.1 (issue #110): the observers only flag dirty; the actual recompute stays lazy.
    /// A burst of dirtying events (several intervening `ResizeObserver`/`MutationObserver`
    /// triggers, simulated here by calling `window.__fenScrollSyncMarkDirty` directly, the exact
    /// function both observers' callbacks invoke) before a single read must still cost exactly
    /// one rebuild, not one per event.
    @Test("A burst of markDirty calls before a read costs exactly one rebuild")
    @MainActor
    func burstOfMarkDirtyCallsCostsOneRebuild() async throws {
        let (markdown, sourceLineCount) = Self.unevenDensityDocument()
        var opts = MarkdownRenderer.Options()
        opts.sourcePositions = true
        let webView = try await renderPreviewWebView(
            markdown: markdown,
            options: opts,
            sourceLineCount: sourceLineCount
        )
        _ = try await pollUntilTrue(
            webView,
            js: "document.documentElement.scrollHeight > document.documentElement.clientHeight"
        )
        _ = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let baseline = try #require(
            try await webView.evaluateJavaScript("window.__fenScrollSyncRebuildCount") as? Double
        )

        _ = try await webView.evaluateJavaScript("""
        (function () {
            for (var i = 0; i < 5; i++) {
                window.__fenScrollSyncMarkDirty();
            }
        })();
        """)

        let afterBurstBeforeRead = try #require(
            try await webView.evaluateJavaScript("window.__fenScrollSyncRebuildCount") as? Double
        )
        #expect(afterBurstBeforeRead == baseline, "Rebuild must not happen inside the markDirty burst itself")

        _ = try await webView.evaluateJavaScript("window.__fenScrollSync.lineNumberAnchors();")
        let afterRead = try #require(
            try await webView.evaluateJavaScript("window.__fenScrollSyncRebuildCount") as? Double
        )
        #expect(
            afterRead == baseline + 1,
            """
            Expected exactly one rebuild for the read following a burst of 5 markDirty calls, got \
            \(afterRead - baseline)
            """
        )
    }

    // No test drives Mermaid's *real* rendering pipeline end to end, deliberately: in this
    // WKWebView-unit-test harness, Mermaid's async init() always finishes before
    // renderPreviewWebView's didFinish returns control to the test, even with every invalidation
    // trigger disabled and a 150-node diagram -- confirmed by trying exactly that. There's no
    // stale window to observe, so a real-render test here would pass unconditionally, proving
    // nothing. anchorTableReflectsLateDOMMutation (the MutationObserver path) and
    // rejectedReadyPromiseStillDirtiesAnchorTable (the ready-promise path) already cover both
    // trigger mechanisms Mermaid's completion actually exercises.
}
