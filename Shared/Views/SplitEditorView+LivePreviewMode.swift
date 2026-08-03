import SwiftUI

/// The Live-Preview/`.editorOnly` single-pane invariant (issue #128), split from
/// `SplitEditorView.swift` to keep that file under swiftlint's file/type length limits.
extension SplitEditorView {
    /// Rule 1.1: Live Preview can already be enabled at launch (a persisted preference, or
    /// `-editorLivePreviewEnabled YES` in tests) with no "turning it on" transition for
    /// `onChange` to observe -- enforce the invariant here too. Nothing to stash: there's no
    /// prior view mode from before the document opened.
    func enforceLivePreviewViewModeInvariantOnAppear() {
        if preferences.editorLivePreviewEnabled {
            viewMode = .editorOnly
        }
    }

    /// Rule 1.1/1.3: Live Preview implies the single `.editorOnly` pane -- turning it on stashes
    /// whatever `viewMode` it overrode so turning it back off can restore it; turning it on from
    /// `.editorOnly` already has nothing to stash.
    func livePreviewEnabledDidChange(isEnabled: Bool) {
        if isEnabled {
            if viewMode != .editorOnly {
                stashedViewModeBeforeLivePreview = viewMode
                viewMode = .editorOnly
            }
        } else if let stashed = stashedViewModeBeforeLivePreview {
            stashedViewModeBeforeLivePreview = nil
            viewMode = stashed
        }
    }

    /// Rule 1.2: the invariant holds in both directions -- manually switching away from
    /// `.editorOnly` (via the picker) while Live Preview is on turns it off, rather than leaving
    /// it silently active behind a pane that no longer shows it.
    func viewModeDidChange(to newValue: SplitEditorView.ViewMode) {
        if newValue != .editorOnly, preferences.editorLivePreviewEnabled {
            stashedViewModeBeforeLivePreview = nil
            preferences.editorLivePreviewEnabled = false
        }
    }
}
