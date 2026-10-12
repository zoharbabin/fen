import FenCore
import Sparkle

/// **Fen > Check for Updates…** (issue #39). With a public key in `Info.plist`, Sparkle does the update. Without
/// one, Fen falls back to the release page. Nothing checks in the background: `SUEnableAutomaticChecks` is off.
@MainActor
enum AppUpdater {
    private static let sparkle: SPUStandardUpdaterController? = {
        guard UpdateChannel.resolve(info: Bundle.main.infoDictionary) == .sparkle else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    static func checkForUpdates() async {
        if let sparkle {
            sparkle.checkForUpdates(nil)
        } else {
            await UpdateChecker.checkAndShow()
        }
    }
}
