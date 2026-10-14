import Foundation

/// Tells Live Preview when a preview setting that changes a picture changes (style, font size, custom CSS,
/// which renderers are on, `$ $` math), so the open note draws again without waiting for an edit.
@MainActor
enum LivePreviewSettingsWatch {
    /// Runs `onChange` after each such change. It keeps watching while `onChange` returns `true`.
    static func watch(_ preferences: Preferences = .shared, onChange: @escaping @MainActor () -> Bool) {
        nonisolated(unsafe) let preferences = preferences
        withObservationTracking {
            _ = LivePreviewSnapshots.look(preferences)
            _ = LivePreviewSnapshots.enabledKinds(preferences)
            _ = preferences.htmlMathJaxInlineDollar
        } onChange: {
            Task { @MainActor in
                if onChange() {
                    watch(preferences, onChange: onChange)
                }
            }
        }
    }
}
