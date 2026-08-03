import Foundation

// MARK: - GeoJSON/TopoJSON interactive maps (issue #121)

extension HTMLComposer {
    /// Renders `` ```geojson ``/`` ```topojson `` fenced code blocks as an interactive Leaflet.js
    /// map with a live OpenStreetMap tile basemap -- mirrors `stlViewerTags`'s conditional gating
    /// pattern exactly. `body` is scanned for `class="language-geojson"`/`class="language-topojson"`
    /// so documents with the preference on but no matching block still load zero extra script
    /// (rule 4.1). This is Fen's first-ever runtime network call (tile image requests made by the
    /// vendored Leaflet.js inside the preview's `WKWebView`, not a native `URLSession` call), so
    /// it stays off by default and only fires when `preferences.htmlGeoJSONMaps` is explicitly on.
    func geoJSONMapTags(
        preferences: Preferences,
        body: String
    ) -> (styles: [String], scripts: [String]) {
        guard preferences.htmlGeoJSONMaps,
              body.contains(#"class="language-geojson""#) || body.contains(#"class="language-topojson""#)
        else { return ([], []) }

        let styles = [
            loadExtensionFile(named: "leaflet", ext: "css"),
            loadExtensionFile(named: "geojson-map", ext: "css"),
        ]
        .compactMap(\.self)
        .map { inlineStyle($0) }

        let scripts = [
            loadExtensionFile(named: "leaflet", ext: "js"),
            loadExtensionFile(named: "topojson-client.min", ext: "js"),
            loadExtensionFile(named: "geojson-map-init", ext: "js"),
        ]
        .compactMap(\.self)
        .map { inlineScript($0) }

        return (styles, scripts)
    }
}
