@testable import FenCore
import Foundation
import Testing
import WebKit

/// `interpolateEditorAnchor` (`Shared/Editor/EditorScrollAnchors.swift`) and `interpolate`
/// (`Shared/Resources/ScrollSync/scroll-sync.js`) implement the same piecewise-linear,
/// clamped-endpoint interpolation independently in Swift and JavaScript — the algorithm this
/// whole scroll-sync mechanism depends on to translate between "fraction through the source"
/// and "fraction through the rendered/laid-out pixels." A future edit to either side that
/// changes the math (a different clamp, an off-by-one in the bracketing search, a different
/// tie-break at an anchor boundary) would silently desync the editor and preview again without
/// either language's own unit tests catching it, since each only tests its own implementation
/// against its own inputs. This test drives both with the *same* literal table and the same
/// probe values and asserts they agree, so a divergence between the two shows up here first.
@Suite("Cross-language interpolation parity")
struct CrossLanguageInterpolationTest {
    /// An uneven, non-trivial table — deliberately not evenly spaced on either axis, so a
    /// bracketing-search bug (e.g. an off-by-one at a segment boundary) has a chance to surface.
    private static let table: [EditorLineAnchor] = [
        EditorLineAnchor(source: 0, rendered: 0),
        EditorLineAnchor(source: 0.1, rendered: 0.4),
        EditorLineAnchor(source: 0.5, rendered: 0.55),
        EditorLineAnchor(source: 0.9, rendered: 0.95),
        EditorLineAnchor(source: 1, rendered: 1),
    ]

    private static let probeValues: [CGFloat] = [
        -0.2, 0, 0.05, 0.1, 0.3, 0.5, 0.7, 0.9, 0.95, 1, 1.2,
    ]

    @MainActor
    private func loadScrollSyncWebView() async throws -> WKWebView {
        try await renderPreviewWebView(markdown: "# Just a heading")
    }

    @Test("Swift's interpolateEditorAnchor and JS's interpolate agree on source→rendered")
    @MainActor
    func sourceToRenderedAgrees() async throws {
        let webView = try await loadScrollSyncWebView()
        for value in Self.probeValues {
            let swiftResult = interpolateEditorAnchor(Self.table, from: \.source, to: \.rendered, value: value)
            let jsResult = try await evaluateInterpolate(
                on: webView, fromKey: "source", toKey: "rendered", value: value
            )
            #expect(
                abs(swiftResult - jsResult) < 0.0001,
                "Diverged at value \(value): Swift got \(swiftResult), JS got \(jsResult)"
            )
        }
    }

    @Test("Swift's interpolateEditorAnchor and JS's interpolate agree on rendered→source")
    @MainActor
    func renderedToSourceAgrees() async throws {
        let webView = try await loadScrollSyncWebView()
        for value in Self.probeValues {
            let swiftResult = interpolateEditorAnchor(Self.table, from: \.rendered, to: \.source, value: value)
            let jsResult = try await evaluateInterpolate(
                on: webView, fromKey: "rendered", toKey: "source", value: value
            )
            #expect(
                abs(swiftResult - jsResult) < 0.0001,
                "Diverged at value \(value): Swift got \(swiftResult), JS got \(jsResult)"
            )
        }
    }

    @MainActor
    private func evaluateInterpolate(
        on webView: WKWebView,
        fromKey: String,
        toKey: String,
        value: CGFloat
    ) async throws -> CGFloat {
        let tableJSON = Self.table
            .map { "{source: \($0.source), rendered: \($0.rendered)}" }
            .joined(separator: ", ")
        let js = "window.__fenScrollSync.interpolate([\(tableJSON)], \"\(fromKey)\", \"\(toKey)\", \(value));"
        let result = try await webView.evaluateJavaScript(js)
        return try #require(result as? CGFloat)
    }
}
