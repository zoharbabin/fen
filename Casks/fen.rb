cask "fen" do
  version "0.6.2"
  sha256 "15709b20281fe47106146955571a79be13b1a25c847faab78565e0a853a177cb"

  url "https://github.com/zoharbabin/fen/releases/download/v#{version}/Fen.app.zip"
  name "Fen"
  desc "Native Markdown editor"
  homepage "https://github.com/zoharbabin/fen"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Fen.app"

  zap trash: [
    "~/Library/Caches/com.zoharbabin.fen",
    "~/Library/Preferences/com.zoharbabin.fen.plist",
    "~/Library/Saved Application State/com.zoharbabin.fen.savedState",
  ]
end
