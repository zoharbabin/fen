@testable import FenCore
import Foundation
import Testing

@Suite("UpdateChannel")
struct UpdateChannelTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed = "https://github.com/zoharbabin/fen/releases/latest/download/appcast.xml"

    private func info(key: String? = nil, feed: String? = nil) -> [String: Any] {
        ["SUPublicEDKey": key ?? self.key, "SUFeedURL": feed ?? self.feed]
    }

    @Test("A key and a feed on this project's releases select Sparkle")
    func sparkle() {
        #expect(UpdateChannel.resolve(info: info()) == .sparkle)
    }

    @Test("No Info.plist, or no Sparkle keys, falls back to the release page")
    func missing() {
        #expect(UpdateChannel.resolve(info: nil) == .releasePage)
        #expect(UpdateChannel.resolve(info: [:]) == .releasePage)
        #expect(UpdateChannel.resolve(info: ["SUFeedURL": feed]) == .releasePage)
        #expect(UpdateChannel.resolve(info: ["SUPublicEDKey": key]) == .releasePage)
    }

    @Test("A key that isn't 32 bytes of base64 is refused")
    func badKey() {
        #expect(UpdateChannel.resolve(info: info(key: "")) == .releasePage)
        #expect(UpdateChannel.resolve(info: info(key: "not base64!")) == .releasePage)
        #expect(UpdateChannel
            .resolve(info: info(key: Data(repeating: 1, count: 16).base64EncodedString())) == .releasePage)
    }

    @Test("A feed off this project's GitHub releases is refused")
    func badFeed() {
        let feeds = [
            "http://github.com/zoharbabin/fen/releases/latest/download/appcast.xml",
            "https://example.com/zoharbabin/fen/releases/appcast.xml",
            "https://github.com.evil.test/zoharbabin/fen/releases/appcast.xml",
            "https://github.com/someone-else/fen/releases/latest/download/appcast.xml",
            "https://github.com/zoharbabin/fen/raw/master/appcast.xml",
            "not a url",
        ]
        for feed in feeds {
            #expect(UpdateChannel.resolve(info: info(feed: feed)) == .releasePage, "\(feed)")
        }
    }

    @Test("The shipped Info.plist selects Sparkle and never checks in the background")
    func shippedPlist() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        url.appendPathComponent("macOS/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        #expect(UpdateChannel.resolve(info: plist) == .sparkle)
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }
}
