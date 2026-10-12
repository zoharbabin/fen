import Foundation

/// How **Check for Updates…** gets its answer (issue #39).
public enum UpdateChannel: Equatable, Sendable {
    /// Sparkle downloads the new build, checks its signature and replaces the app.
    case sparkle
    /// Fen reads the newest release and opens its page. Builds from source and builds without a key use this.
    case releasePage

    static let feedPathPrefix = "/zoharbabin/fen/releases/"

    /// Sparkle runs only when the app carries a usable public key and a feed on this project's releases.
    /// A missing or malformed value must never start an updater that can't verify what it downloads.
    public static func resolve(info: [String: Any]?) -> UpdateChannel {
        guard let info,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
              feed.scheme == "https",
              feed.host == "github.com",
              feed.path.hasPrefix(feedPathPrefix)
        else { return .releasePage }
        return .sparkle
    }
}
