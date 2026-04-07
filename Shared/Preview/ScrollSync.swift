import Foundation

/// Manages synchronized scrolling between the editor and preview.
///
/// Uses a simple proportional scroll sync approach: the scroll fraction
/// (0.0 to 1.0) from the editor is applied to the preview, and vice versa.
/// This is simpler than the original MacDown header-based approach but works
/// well for most documents.
@Observable
final class ScrollSync {
    enum Source {
        case editor
        case preview
    }

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
