@testable import FenCore
import Testing

/// Issue #42: in iPad Split View both scenes are foreground-active, so one Cmd+B must not run in
/// both. `CommandTarget` is the rule the iOS editor and `SplitEditorView` share.
struct CommandTargetTests {
    @Test
    func aLoneForegroundSceneIsTheTarget() {
        // Single window: behaves as before, even if the editor has no focus yet.
        #expect(CommandTarget.accepts(
            sceneIsForegroundActive: true, foregroundSceneCount: 1, isKeyWindow: false, isFirstResponder: false
        ))
    }

    @Test
    func aBackgroundSceneIsNeverTheTarget() {
        #expect(!CommandTarget.accepts(
            sceneIsForegroundActive: false, foregroundSceneCount: 1, isKeyWindow: true
        ))
        #expect(!CommandTarget.accepts(
            sceneIsForegroundActive: false, foregroundSceneCount: 2, isKeyWindow: true
        ))
    }

    @Test
    func inSplitViewOnlyTheKeyWindowIsTheTarget() {
        #expect(CommandTarget.accepts(
            sceneIsForegroundActive: true, foregroundSceneCount: 2, isKeyWindow: true
        ))
        #expect(!CommandTarget.accepts(
            sceneIsForegroundActive: true, foregroundSceneCount: 2, isKeyWindow: false
        ))
    }

    @Test
    func inSplitViewAnEditorAlsoNeedsFirstResponder() {
        #expect(!CommandTarget.accepts(
            sceneIsForegroundActive: true, foregroundSceneCount: 2, isKeyWindow: true, isFirstResponder: false
        ))
    }
}
