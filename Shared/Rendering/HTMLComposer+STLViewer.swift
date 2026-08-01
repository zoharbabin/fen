import Foundation

// MARK: - STL 3D Viewer (issue #120)

extension HTMLComposer {
    /// Renders ASCII STL fenced code blocks (`` ```stl ``) as an interactive 3D viewer, using
    /// the vendored three.js + STLLoader + OrbitControls -- mirrors `mermaidTags`' conditional
    /// gating pattern. `body` is scanned for `class="language-stl"` (the exact class cmark-gfm's
    /// fenced-code renderer emits for a `stl`-tagged block, matching `mermaidTags`'/
    /// `taskListTags`' own "only pay the cost when the feature is actually used" reasoning) so
    /// documents with the preference on but no `stl` block still load zero extra script (rule
    /// 4.1). three.js/STLLoader/OrbitControls are static vendored files with no network access
    /// (rule 2.2).
    func stlViewerTags(
        preferences: Preferences,
        body: String
    ) -> (styles: [String], scripts: [String]) {
        guard preferences.htmlSTLViewer, body.contains(#"class="language-stl""#) else { return ([], []) }

        let styles = [loadExtensionFile(named: "stl-viewer", ext: "css")]
            .compactMap(\.self)
            .map { inlineStyle($0) }

        let scripts = [
            loadExtensionFile(named: "three.min", ext: "js"),
            loadExtensionFile(named: "STLLoader", ext: "js"),
            loadExtensionFile(named: "OrbitControls", ext: "js"),
            loadExtensionFile(named: "stl-viewer-init", ext: "js"),
        ]
        .compactMap(\.self)
        .map { inlineScript($0) }

        return (styles, scripts)
    }
}
