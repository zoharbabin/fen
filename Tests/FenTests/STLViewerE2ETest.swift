@testable import FenCore
import Foundation
import Testing
import WebKit

/// Proves issue #120's rules end-to-end through the real `MarkdownRenderer` → `HTMLComposer` →
/// `PreviewSchemeHandler` pipeline into a real `WKWebView` -- a string-content check on the
/// composed HTML can't see whether three.js actually parsed the geometry and painted a canvas,
/// since that only happens once real JS executes (same reasoning as
/// `MermaidErrorPanelVerifyTest.swift`).
@Suite("STL 3D viewer")
struct STLViewerE2ETest {
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

    private static let cubeFaceTwoFacets = """
    solid cube
    facet normal 0 0 -1
    outer loop
    vertex 0 0 0
    vertex 0 1 0
    vertex 1 1 0
    endloop
    endfacet
    facet normal 0 0 -1
    outer loop
    vertex 0 0 0
    vertex 1 1 0
    vertex 1 0 0
    endloop
    endfacet
    endsolid cube
    """

    @Test("A valid stl block renders as a canvas-backed 3D viewer")
    @MainActor
    func validSTLRendersCanvas() async throws {
        let markdown = "```stl\n\(Self.validASCIISTL)\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        let rendered = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-container canvas').length === 1"
        )
        #expect(rendered, "Expected exactly one STL viewer canvas for the valid block")

        let rawTextGone = try await webView.evaluateJavaScript(
            "!!document.querySelector('code.language-stl')"
        ) as? Bool ?? true
        #expect(!rawTextGone, "Expected the raw fenced-code element replaced by the viewer container")
    }

    @Test("The canvas actually paints the model, not just an empty black frame")
    @MainActor
    func canvasPaintsNonBlackPixels() async throws {
        // Uses a two-facet flat square (matching the demo.md cube example) rather than
        // `validASCIISTL`'s single triangle -- a model whose faces happen to wind away from the
        // default camera silently renders nothing under `THREE.FrontSide` (three.js's material
        // default), which a canvas-element-exists check can't detect. Regression test for the
        // all-black-canvas bug found in manual verification.
        let markdown = "```stl\n\(Self.cubeFaceTwoFacets)\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-container canvas').length === 1"
        )

        let nonBlackPixelCount = try await webView.evaluateJavaScript("""
        (function () {
            var canvas = document.querySelector('.fen-stl-container canvas');
            var ctx2d = document.createElement('canvas').getContext('2d');
            ctx2d.canvas.width = canvas.width;
            ctx2d.canvas.height = canvas.height;
            ctx2d.drawImage(canvas, 0, 0);
            var data = ctx2d.getImageData(0, 0, canvas.width, canvas.height).data;
            var nonBlack = 0;
            for (var i = 0; i < data.length; i += 4) {
                if (data[i] > 5 || data[i + 1] > 5 || data[i + 2] > 5) nonBlack++;
            }
            return nonBlack;
        })();
        """) as? Int
        #expect(
            (nonBlackPixelCount ?? 0) > 0,
            "Expected the canvas to actually paint the model's geometry, not render an all-black frame"
        )
    }

    @Test("The preference off leaves the block as plain code, no three.js loaded")
    @MainActor
    func preferenceOffLeavesPlainCode() async throws {
        let markdown = "```stl\n\(Self.validASCIISTL)\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = false
        }

        let stillRaw = try await webView.evaluateJavaScript(
            "!!document.querySelector('code.language-stl')"
        ) as? Bool ?? false
        #expect(stillRaw, "Expected the stl block to stay as plain highlighted code when the preference is off")

        let threeLoaded = try await webView.evaluateJavaScript("typeof THREE") as? String
        #expect(threeLoaded == "undefined", "Expected three.js not to load when htmlSTLViewer is off")
    }

    @Test("A document with no stl block never loads three.js even with the preference on")
    @MainActor
    func noSTLBlockSkipsLoadingThreeJS() async throws {
        let webView = try await renderPreviewWebView(markdown: "# Just a heading, no STL here") { prefs in
            prefs.htmlSTLViewer = true
        }

        let threeLoaded = try await webView.evaluateJavaScript("typeof THREE") as? String
        #expect(
            threeLoaded == "undefined",
            "Expected three.js not to load into a document with no stl block (rule 4.1)"
        )
    }

    @Test("Malformed STL content shows an inline error panel, not a blank crash")
    @MainActor
    func malformedSTLShowsErrorPanel() async throws {
        let markdown = "```stl\nthis is not valid stl at all !!\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        let errorShown = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-error').length === 1"
        )
        #expect(errorShown, "Expected an inline error panel for malformed STL content")

        let noUncaughtErrorBrokeTheRest = try await webView.evaluateJavaScript(
            "document.body !== null"
        ) as? Bool ?? false
        #expect(
            noUncaughtErrorBrokeTheRest,
            "Expected the rest of the document to still render after a malformed block"
        )
    }

    @Test("A broken stl block doesn't take down a later valid one in the same document")
    @MainActor
    func brokenBlockDoesNotBlockLaterViewer() async throws {
        let markdown = """
        ```stl
        garbage not stl
        ```

        ```stl
        \(Self.validASCIISTL)
        ```
        """
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        let bothResolved = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-error').length === 1 && " +
                "document.querySelectorAll('.fen-stl-container canvas').length === 1"
        )
        #expect(bothResolved, "Expected the first block to error and the second to still render")
    }

    @Test("HTML-special byte sequences inside STL content never execute as markup")
    @MainActor
    func htmlSpecialContentStaysInert() async throws {
        let dangerousSTL = """
        solid </script><script>window.__fenPwned = true;</script>
        facet normal 0 0 1
        outer loop
        vertex 0 0 0
        vertex 1 0 0
        vertex 0 1 0
        endloop
        endfacet
        endsolid test
        """
        let markdown = "```stl\n\(dangerousSTL)\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-container, .fen-stl-error').length === 1"
        )

        let pwned = try await webView.evaluateJavaScript("!!window.__fenPwned") as? Bool ?? false
        #expect(!pwned, "A </script><script> sequence inside STL content must never execute as markup")
    }

    @Test("Two independent viewers in one document don't share three.js scene state")
    @MainActor
    func twoViewersDoNotShareState() async throws {
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
        #expect(bothRendered, "Expected two independent canvases, one per stl block (rule 1.1)")

        let independentCanvases = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-stl-container canvas')[0] !== " +
                "document.querySelectorAll('.fen-stl-container canvas')[1]"
        ) as? Bool ?? false
        #expect(independentCanvases)
    }

    @Test("An oversized synthetic STL falls back to a message instead of hanging")
    @MainActor
    func oversizedSTLFallsBackToMessage() async throws {
        var facets = "solid huge\n"
        for _ in 0 ..< 500_001 {
            facets += "facet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\n"
        }
        facets += "endsolid huge"
        let markdown = "```stl\n\(facets)\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        let fallbackShown = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-error').length === 1",
            timeout: .seconds(15)
        )
        #expect(fallbackShown, "Expected a fallback message for a facet count exceeding the documented cap")
    }

    @Test("The wireframe toggle button flips the material's wireframe flag and its own aria-pressed state")
    @MainActor
    func wireframeToggleFlipsMaterialState() async throws {
        let markdown = "```stl\n\(Self.validASCIISTL)\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-wireframe-toggle').length === 1"
        )

        let initiallyPressed = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-stl-wireframe-toggle').getAttribute('aria-pressed')"
        ) as? String
        #expect(initiallyPressed == "false", "Expected the toggle to start unpressed (shaded render)")

        _ = try await webView.evaluateJavaScript("document.querySelector('.fen-stl-wireframe-toggle').click()")

        let pressedAfterClick = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-stl-wireframe-toggle').getAttribute('aria-pressed')"
        ) as? String
        #expect(pressedAfterClick == "true", "Expected one click to flip the button to pressed (wireframe on)")

        _ = try await webView.evaluateJavaScript("document.querySelector('.fen-stl-wireframe-toggle').click()")

        let pressedAfterSecondClick = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-stl-wireframe-toggle').getAttribute('aria-pressed')"
        ) as? String
        #expect(pressedAfterSecondClick == "false", "Expected a second click to flip back to unpressed (shaded)")
    }

    @Test("Toggling wireframe repeatedly never re-parses geometry or breaks the render loop (issue #122)")
    @MainActor
    func wireframeToggleNeverReparsesGeometryOrBreaksRenderLoop() async throws {
        let markdown = "```stl\n\(Self.validASCIISTL)\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-wireframe-toggle').length === 1"
        )

        var uncaughtError = false
        _ = try await webView.evaluateJavaScript("""
        (function () {
            window.__fenUncaughtErrorSeen = false;
            window.onerror = function () { window.__fenUncaughtErrorSeen = true; };
            var canvas = document.querySelector('.fen-stl-container canvas');
            window.__fenGeometryBefore = canvas.__fenGeometry;
            var toggle = document.querySelector('.fen-stl-wireframe-toggle');
            toggle.click();
            toggle.click();
            toggle.click();
        })();
        """)
        uncaughtError = try await webView.evaluateJavaScript("window.__fenUncaughtErrorSeen") as? Bool ?? true
        #expect(!uncaughtError, "Expected repeated wireframe toggling to never throw an uncaught error")

        let geometryUnchanged = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-stl-container canvas').__fenGeometry === window.__fenGeometryBefore"
        ) as? Bool ?? false
        #expect(
            geometryUnchanged,
            "Expected the BufferGeometry to be referentially unchanged after repeated wireframe toggling"
        )

        let stillOrbiting = try await pollUntilTrue(
            webView,
            js: """
            (function () {
                var canvas = document.querySelector('.fen-stl-container canvas');
                var rect = canvas.getBoundingClientRect();
                var down = { pointerId: 1, clientX: rect.left + 10, clientY: rect.top + 10, bubbles: true };
                canvas.dispatchEvent(new PointerEvent('pointerdown', down));
                var move = { pointerId: 1, clientX: rect.left + 60, clientY: rect.top + 40, bubbles: true };
                canvas.dispatchEvent(new PointerEvent('pointermove', move));
                canvas.dispatchEvent(new PointerEvent('pointerup', move));
                return canvas.__fenOrbitChangeCount > 0;
            })();
            """
        )
        #expect(
            stillOrbiting,
            "Expected the render/orbit loop to still respond to drag after repeated wireframe toggling"
        )
    }

    @Test("The wireframe toggle never uses an inline onclick attribute (issue #122 rule 2.1)")
    @MainActor
    func wireframeToggleUsesNoInlineHandler() async throws {
        let markdown = "```stl\n\(Self.validASCIISTL)\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-wireframe-toggle').length === 1"
        )

        let hasInlineHandler = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-stl-wireframe-toggle').hasAttribute('onclick')"
        ) as? Bool ?? true
        #expect(
            !hasInlineHandler,
            "Expected the toggle button to be wired via addEventListener, never an inline onclick attribute"
        )
    }

    @Test("Malformed or oversized STL blocks get no wireframe toggle button (issue #122 rule 2.2)")
    @MainActor
    func errorPanelsGetNoWireframeToggle() async throws {
        let markdown = "```stl\nthis is not valid stl at all !!\n```"
        let webView = try await renderPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlSTLViewer = true
        }

        _ = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-stl-error').length === 1"
        )

        let toggleCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-stl-wireframe-toggle').length"
        ) as? Int
        #expect(toggleCount == 0, "Expected no wireframe toggle button alongside an error panel")
    }
}
