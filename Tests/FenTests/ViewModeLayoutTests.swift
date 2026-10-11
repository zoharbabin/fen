@testable import FenCore
import Testing

/// Issue #42: a narrow window shows one pane, and the view commands work from what is on screen.
struct ViewModeLayoutTests {
    typealias Mode = SplitEditorView.ViewMode

    @Test
    func aWideWindowOffersAllThreeModes() {
        #expect(Mode.available(compactWidth: false) == [.split, .editorOnly, .previewOnly])
    }

    @Test
    func aNarrowWindowHasNoSplit() {
        #expect(Mode.available(compactWidth: true) == [.editorOnly, .previewOnly])
    }

    @Test
    func splitFallsBackToTheEditorOnlyWhenNarrow() {
        #expect(Mode.split.shown(compactWidth: true) == .editorOnly)
        #expect(Mode.split.shown(compactWidth: false) == .split)
        #expect(Mode.previewOnly.shown(compactWidth: true) == .previewOnly)
        #expect(Mode.editorOnly.shown(compactWidth: true) == .editorOnly)
    }

    @Test(arguments: [Mode.split, .editorOnly, .previewOnly])
    func theShownModeIsAlwaysOneThePickerOffers(mode: Mode) {
        for compact in [true, false] {
            #expect(Mode.available(compactWidth: compact).contains(mode.shown(compactWidth: compact)))
        }
    }

    @Test
    func togglePreviewHidesThenShowsThePreview() {
        #expect(Mode.split.afterTogglingPreview(compactWidth: false) == .editorOnly)
        #expect(Mode.editorOnly.afterTogglingPreview(compactWidth: false) == .split)
        #expect(Mode.previewOnly.afterTogglingPreview(compactWidth: false) == .editorOnly)
    }

    @Test
    func toggleEditorHidesThenShowsTheEditor() {
        #expect(Mode.split.afterTogglingEditor(compactWidth: false) == .previewOnly)
        #expect(Mode.previewOnly.afterTogglingEditor(compactWidth: false) == .split)
        #expect(Mode.editorOnly.afterTogglingEditor(compactWidth: false) == .previewOnly)
    }

    /// A stored `.split` shows the editor when narrow, so the first toggle has to move to the preview.
    @Test
    func theTogglesActOnWhatIsOnScreenWhenNarrow() {
        #expect(Mode.split.afterTogglingPreview(compactWidth: true) == .previewOnly)
        #expect(Mode.editorOnly.afterTogglingPreview(compactWidth: true) == .previewOnly)
        #expect(Mode.previewOnly.afterTogglingPreview(compactWidth: true) == .editorOnly)
        #expect(Mode.previewOnly.afterTogglingEditor(compactWidth: true) == .editorOnly)
        #expect(Mode.split.afterTogglingEditor(compactWidth: true) == .previewOnly)
    }

    @Test(arguments: [Mode.split, .editorOnly, .previewOnly])
    func aToggleNeverLeavesNoPane(mode: Mode) {
        for compact in [true, false] {
            for next in [
                mode.afterTogglingPreview(compactWidth: compact),
                mode.afterTogglingEditor(compactWidth: compact),
            ] {
                #expect(Mode.available(compactWidth: compact).contains(next.shown(compactWidth: compact)))
            }
        }
    }
}
