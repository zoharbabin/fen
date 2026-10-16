cask "fen" do
  version "0.7.0"
  sha256 "6e95c6417df39a1f5ce4c2c74615321d14399d2b2a0d509fb3ed5d0ed47f058a"

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
