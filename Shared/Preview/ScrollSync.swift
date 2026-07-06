import Foundation

/// Manages synchronized scrolling between the editor and preview.
///
/// Both fractions here are *source-document* fractions — "how far through the raw
/// Markdown text," not "how far through this pane's own pixels." Each pane owns the
/// translation between its raw pixel-scroll-fraction and that shared source fraction
/// (the editor via `EditorScrollAnchors.swift`'s word-wrap anchor table, the preview
/// via `scroll-sync.js`'s `data-sourcepos` anchor table) before calling in or reading
/// out here — see [ARCHITECTURE.md](../../docs/ARCHITECTURE.md#editing-to-preview-the-rendering-pipeline)
/// for why a raw 1:1 pixel mirror drifts on documents where the source and rendered
/// content don't share the same density throughout.
@Observable
final class ScrollSync {
    var editorScrollFraction: CGFloat = 0
    var previewScrollFraction: CGFloat = 0

    private var isUpdating = false

    /// Call when the editor scroll position changes.
    func editorDidScroll(to fraction: CGFloat) {
        guard !isUpdating else { return }
        isUpdating = true
        editorScrollFraction = fraction
        previewScrollFraction = fraction
        isUpdating = false
    }

    /// Call when the preview scroll position changes.
    func previewDidScroll(to fraction: CGFloat) {
        guard !isUpdating else { return }
        isUpdating = true
        previewScrollFraction = fraction
        editorScrollFraction = fraction
        isUpdating = false
    }
}
