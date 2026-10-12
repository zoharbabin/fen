#if os(iOS)
    import UIKit
#endif

/// Decides whether one window or editor is the target of a menu command (issue #42).
///
/// Commands travel as notifications, so every open window hears them. On macOS the key window is
/// the target. On iPad, both apps in Split View are foreground-active, so a scene check alone
/// would run the command twice. With two or more active scenes, only the key window (and, for an
/// editor, its first responder) is the target.
enum CommandTarget {
    static func accepts(
        sceneIsForegroundActive: Bool,
        foregroundSceneCount: Int,
        isKeyWindow: Bool,
        isFirstResponder: Bool = true
    ) -> Bool {
        guard sceneIsForegroundActive else { return false }
        return foregroundSceneCount < 2 || (isKeyWindow && isFirstResponder)
    }

    #if os(iOS)
        /// The same decision for a real iPad window. A window with no scene yet is not a target.
        @MainActor
        static func accepts(window: UIWindow?, isFirstResponder: Bool = true) -> Bool {
            guard let scene = window?.windowScene else { return false }
            let activeScenes = UIApplication.shared.connectedScenes
                .filter { $0.activationState == .foregroundActive }
            return accepts(
                sceneIsForegroundActive: scene.activationState == .foregroundActive,
                foregroundSceneCount: activeScenes.count,
                isKeyWindow: window?.isKeyWindow == true,
                isFirstResponder: isFirstResponder
            )
        }
    #endif
}
