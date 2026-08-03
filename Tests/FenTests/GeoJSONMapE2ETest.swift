@testable import FenCore
import Foundation
import Testing
import WebKit

/// Proves issue #121's rules end-to-end through the real `MarkdownRenderer` → `HTMLComposer` →
/// `PreviewSchemeHandler` pipeline into a real `WKWebView` -- a string-content check on the
/// composed HTML can't see whether Leaflet actually parsed the GeoJSON and painted a map, since
/// that only happens once real JS executes (same reasoning as `STLViewerE2ETest`).
///
/// No test in this file makes a real request to OpenStreetMap's tile servers: every test either
/// leaves `htmlGeoJSONMaps` off, or injects `window.__fenGeoJSONTileURLOverride` (via a
/// `WKUserScript` at document-start, before `geojson-map-init.js` reads it) pointing at an
/// unreachable host, matching rule 2.3's/3.1's intent without depending on network access in CI.
@Suite("GeoJSON/TopoJSON maps")
struct GeoJSONMapE2ETest {
    private static let simpleFeature = """
    {
      "type": "Feature",
      "properties": { "title": "Fen HQ", "description": "Where the bugs are fixed" },
      "geometry": { "type": "Point", "coordinates": [-122.4194, 37.7749] }
    }
    """

    private static let simpleTopology = """
    {
      "type": "Topology",
      "objects": {
        "example": {
          "type": "GeometryCollection",
          "geometries": [
            { "type": "Point", "properties": { "title": "Node" }, "coordinates": [0, 0] }
          ]
        }
      },
      "arcs": [],
      "transform": { "scale": [1, 1], "translate": [0, 0] }
    }
    """

    /// Injects `window.__fenGeoJSONTileURLOverride` at `.atDocumentStart` -- before any page
    /// script (including `geojson-map-init.js`, which reads that override at its own
    /// `window.load` time) runs -- so the vendored Leaflet.js never fetches a real OpenStreetMap
    /// tile during tests.
    @MainActor
    private func renderGeoJSONPreviewWebView(
        markdown: String,
        tileURLOverride: String = "https://fen-test-unreachable.invalid/{z}/{x}/{y}.png",
        configurePreferences: @escaping (Preferences) -> Void = { _ in }
    ) async throws -> WKWebView {
        let overrideScript = WKUserScript(
            source: "window.__fenGeoJSONTileURLOverride = \(String(reflecting: tileURLOverride));",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        return try await renderPreviewWebView(
            markdown: markdown,
            configurePreferences: configurePreferences,
            userScripts: [overrideScript]
        )
    }

    @Test("A geojson block renders as an interactive Leaflet map")
    @MainActor
    func validGeoJSONRendersMap() async throws {
        let markdown = "```geojson\n\(Self.simpleFeature)\n```"
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        let rendered = try await pollUntilTrue(
            webView, js: "!!document.querySelector('.fen-geojson-container .leaflet-container')"
        )
        #expect(rendered, "Expected the geojson block to render as a Leaflet map container")

        let rawGone = try await webView.evaluateJavaScript(
            "!!document.querySelector('code.language-geojson')"
        ) as? Bool ?? true
        #expect(!rawGone, "Expected the raw fenced-code element replaced by the map container")
    }

    @Test("A topojson block converts and renders the same as a geojson block")
    @MainActor
    func validTopoJSONRendersMap() async throws {
        let markdown = "```topojson\n\(Self.simpleTopology)\n```"
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        let rendered = try await pollUntilTrue(
            webView, js: "!!document.querySelector('.fen-geojson-container .leaflet-container')"
        )
        #expect(rendered, "Expected the topojson block to convert and render as a Leaflet map container")
    }

    @Test("The preference off leaves the block as plain code, no Leaflet loaded")
    @MainActor
    func preferenceOffLeavesPlainCode() async throws {
        let markdown = "```geojson\n\(Self.simpleFeature)\n```"
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = false
        }

        let stillRaw = try await webView.evaluateJavaScript(
            "!!document.querySelector('code.language-geojson')"
        ) as? Bool ?? false
        #expect(stillRaw, "Expected the geojson block to stay as plain highlighted code when the preference is off")

        let leafletLoaded = try await webView.evaluateJavaScript("typeof L") as? String
        #expect(leafletLoaded == "undefined", "Expected Leaflet not to load when htmlGeoJSONMaps is off")
    }

    @Test("A document with no geo block never loads Leaflet even with the preference on")
    @MainActor
    func noGeoBlockSkipsLoadingLeaflet() async throws {
        let webView = try await renderGeoJSONPreviewWebView(markdown: "# Just a heading, no map here") { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        let leafletLoaded = try await webView.evaluateJavaScript("typeof L") as? String
        #expect(
            leafletLoaded == "undefined",
            "Expected Leaflet not to load into a document with no geo block (rule 4.1)"
        )
    }

    @Test("Malformed JSON shows an inline error panel, not a blank crash")
    @MainActor
    func malformedJSONShowsErrorPanel() async throws {
        let markdown = "```geojson\nthis is not valid json at all !!\n```"
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        let errorShown = try await pollUntilTrue(
            webView, js: "document.querySelectorAll('.fen-geojson-error').length === 1"
        )
        #expect(errorShown, "Expected an inline error panel for malformed GeoJSON content")

        let stillIntact = try await webView.evaluateJavaScript("document.body !== null") as? Bool ?? false
        #expect(stillIntact, "Expected the rest of the document to still render after a malformed block")
    }

    @Test("A broken geo block doesn't take down a later valid one in the same document")
    @MainActor
    func brokenBlockDoesNotBlockLaterMap() async throws {
        let markdown = """
        ```geojson
        garbage not geojson
        ```

        ```geojson
        \(Self.simpleFeature)
        ```
        """
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        let bothResolved = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-geojson-error').length === 1 && " +
                "document.querySelectorAll('.fen-geojson-container .leaflet-container').length === 1"
        )
        #expect(bothResolved, "Expected the first block to error and the second to still render")
    }

    @Test("HTML-special byte sequences inside feature properties never execute as markup")
    @MainActor
    func htmlSpecialPropertyContentStaysInert() async throws {
        let dangerousFeature = """
        {
          "type": "Feature",
          "properties": {
            "title": "</script><script>window.__fenPwned = true;</script>",
            "description": "<img src=x onerror=\\"window.__fenPwned = true\\">"
          },
          "geometry": { "type": "Point", "coordinates": [0, 0] }
        }
        """
        let markdown = "```geojson\n\(dangerousFeature)\n```"
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        _ = try await pollUntilTrue(
            webView, js: "!!document.querySelector('.fen-geojson-container .leaflet-container')"
        )

        // Click the marker to actually build and insert the popup content -- inert-until-clicked
        // content wouldn't prove anything, since the injection (if any) only happens on insertion.
        _ = try await webView.evaluateJavaScript("""
        (function () {
            var marker = document.querySelector('.leaflet-marker-icon');
            if (marker) { marker.click(); }
        })();
        """)
        _ = try await pollUntilTrue(webView, js: "!!document.querySelector('.fen-geojson-popup')")

        let pwned = try await webView.evaluateJavaScript("!!window.__fenPwned") as? Bool ?? false
        #expect(!pwned, "A </script><script> or onerror sequence inside feature properties must never execute")

        let titleTextIntact = try await webView.evaluateJavaScript(
            "(document.querySelector('.fen-geojson-popup-title') || {}).textContent"
        ) as? String
        #expect(
            titleTextIntact?.contains("<script>") == true,
            "Expected the dangerous title to appear as literal, inert text, not stripped or executed"
        )
    }

    @Test("Two independent maps in one document don't share Leaflet state")
    @MainActor
    func twoMapsDoNotShareState() async throws {
        let markdown = """
        ```geojson
        \(Self.simpleFeature)
        ```

        ```geojson
        \(Self.simpleFeature)
        ```
        """
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        let bothRendered = try await pollUntilTrue(
            webView,
            js: "document.querySelectorAll('.fen-geojson-container .leaflet-container').length === 2"
        )
        #expect(bothRendered, "Expected two independent map containers, one per geo block (rule 1.1)")

        let independentContainers = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.fen-geojson-container .leaflet-container')[0] !== " +
                "document.querySelectorAll('.fen-geojson-container .leaflet-container')[1]"
        ) as? Bool ?? false
        #expect(independentContainers)
    }

    @Test("A marker-color point keeps its simplestyle color after Leaflet's own resetStyle pass")
    @MainActor
    func markerColorSurvivesResetStyle() async throws {
        let coloredFeature = """
        {
          "type": "Feature",
          "properties": { "title": "Golden Gate Bridge", "marker-color": "#e6194b" },
          "geometry": { "type": "Point", "coordinates": [-122.4783, 37.8199] }
        }
        """
        let markdown = "```geojson\n\(coloredFeature)\n```"
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        _ = try await pollUntilTrue(
            webView, js: "!!document.querySelector('.fen-geojson-container path.leaflet-interactive')"
        )

        // L.geoJSON re-applies its `style` callback to every layer right after creation
        // (Leaflet's own `resetStyle`), including circleMarkers built by `pointToLayer` -- a
        // `style` callback that doesn't also honor `marker-color` silently overwrites the
        // marker's color with its line/fill defaults once that pass runs.
        let strokeColor = try await webView.evaluateJavaScript(
            "document.querySelector('.fen-geojson-container path.leaflet-interactive').getAttribute('stroke')"
        ) as? String
        #expect(
            strokeColor?.lowercased() == "#e6194b",
            "Expected the marker-color property to still be applied after Leaflet's style-reset pass"
        )
    }

    @Test("A tile load failure still renders the shape, not a blank map (rule 3.1)")
    @MainActor
    func tileLoadFailureStillRendersShapes() async throws {
        let markdown = "```geojson\n\(Self.simpleFeature)\n```"
        // The default override already points at an unreachable host -- every test in this file
        // already proves tile failure never blocks rendering; this test names that guarantee
        // explicitly and asserts on the marker itself, not just the map container.
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        let markerRendered = try await pollUntilTrue(
            webView, js: "!!document.querySelector('.leaflet-marker-icon')"
        )
        #expect(markerRendered, "Expected the point feature's marker to render even though its tile layer never loads")
    }

    @Test("An oversized GeoJSON payload falls back to an error message instead of hanging")
    @MainActor
    func oversizedGeoJSONFallsBackToMessage() async throws {
        var coordinates = "["
        for i in 0 ..< 400_000 {
            coordinates += (i == 0 ? "" : ",") + "[\(Double(i) / 1000), \(Double(i) / 1000)]"
        }
        coordinates += "]"
        let huge = """
        { "type": "Feature", "properties": {}, "geometry": { "type": "LineString", "coordinates": \(coordinates) } }
        """
        let markdown = "```geojson\n\(huge)\n```"
        let webView = try await renderGeoJSONPreviewWebView(markdown: markdown) { prefs in
            prefs.htmlGeoJSONMaps = true
        }

        let fallbackShown = try await pollUntilTrue(
            webView, js: "document.querySelectorAll('.fen-geojson-error').length === 1", timeout: .seconds(15)
        )
        #expect(fallbackShown, "Expected a fallback message for a source length exceeding the documented cap")
    }
}
