@testable import FenCore
import Foundation
import Testing
import WebKit

/// Harness gate 3 for issue #120: proves each `stl` block's three.js `Scene`/`Renderer`/
/// `OrbitControls` are scoped to their own container with no shared module-level state, per rule
/// 1.1 -- renders two independent `stl` blocks in one document and asserts each gets its own
/// canvas, then rotates one viewer's camera and confirms the other's is untouched. Mirrors
/// `EmojiShortcodeIsolationTests.swift`'s intent, but this needs a real `WKWebView` (not a plain
/// Swift struct) since the state under test lives in three.js JS objects, not Swift values.
@Suite("STL viewer isolation")
struct STLViewerIsolationTests {
    private static let validASCIISTL = """
    solid cube
    facet normal 0 0 1
    outer loop
    vertex 0 0 0
    vertex 1 0 0
    vertex 0 1 0
    endloop
    endfacet
    endsolid cube
    """

    @Test("Two stl blocks in one document get independent canvas/renderer instances")
    @MainActor
    func twoBlocksGetIndependentCanvases() async throws {
        let markdown = """
        ```stl
        \(Self.validASCIISTL)
        ```

        ```stl
        \(Self.validASCIISTL)
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        let bothRendered = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-container canvas').length === 2"
        )
        #expect(bothRendered, "Expected two independent canvases, one per stl block")

        let independentCanvases = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-stl-container canvas')[0] !== " +
                "document.querySelectorAll('.fen-stl-container canvas')[1]"
        ) as? Bool ?? false
        #expect(independentCanvases, "Expected distinct canvas elements, not the same node reused")
    }

    @Test("Rotating one viewer's camera does not move the other viewer's camera")
    @MainActor
    func rotatingOneViewerDoesNotAffectTheOther() async throws {
        let markdown = """
        ```stl
        \(Self.validASCIISTL)
        ```

        ```stl
        \(Self.validASCIISTL)
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-container canvas').length === 2"
        )

        // Dispatch synthetic orbit-drag events on the first canvas only, then confirm the second
        // canvas's own orbit-change counter (`canvas.__fenOrbitChangeCount`, set by
        // `stl-viewer-init.js`, scoped per-canvas) never increments -- if camera/controls state
        // were shared, dragging the first would move the second's camera too.
        let secondChangeCountBefore = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-stl-container canvas')[1].__fenOrbitChangeCount"
        ) as? Int
        #expect(secondChangeCountBefore == 0, "Expected the second viewer's orbit-change counter to start at zero")

        _ = try await webView.evaluateJavaScript("""
        (function () {
            var canvas = document.querySelectorAll('.fen-stl-container canvas')[0];
            var rect = canvas.getBoundingClientRect();
            var down = { pointerId: 1, clientX: rect.left + 10, clientY: rect.top + 10, bubbles: true };
            canvas.dispatchEvent(new PointerEvent('pointerdown', down));
            var move = { pointerId: 1, clientX: rect.left + 80, clientY: rect.top + 60, bubbles: true };
            canvas.dispatchEvent(new PointerEvent('pointermove', move));
            canvas.dispatchEvent(new PointerEvent('pointerup', move));
        })();
        """)

        let firstCanvasChanged = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-container canvas')[0].__fenOrbitChangeCount > 0"
        )
        #expect(
            firstCanvasChanged,
            "Expected the drag to actually rotate the first viewer's camera, proving the gesture had effect"
        )

        let secondChangeCountAfter = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-stl-container canvas')[1].__fenOrbitChangeCount"
        ) as? Int

        #expect(
            secondChangeCountAfter == 0,
            "Expected the second viewer's camera to be unaffected by dragging the first viewer's camera"
        )
    }

    @Test("Toggling one viewer's wireframe button does not affect the other viewer (issue #122 rule 1.1)")
    @MainActor
    func togglingOneWireframeDoesNotAffectTheOther() async throws {
        let markdown = """
        ```stl
        \(Self.validASCIISTL)
        ```

        ```stl
        \(Self.validASCIISTL)
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-wireframe-toggle').length === 2"
        )

        _ = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-stl-wireframe-toggle')[0].click()"
        )

        let firstPressed = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-stl-wireframe-toggle')[0].getAttribute('aria-pressed')"
        ) as? String
        #expect(firstPressed == "true", "Expected the clicked button's own state to flip to pressed")

        let secondPressed = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-stl-wireframe-toggle')[1].getAttribute('aria-pressed')"
        ) as? String
        #expect(
            secondPressed == "false",
            "Expected the second viewer's wireframe toggle to stay untouched by the first viewer's click"
        )
    }
}
