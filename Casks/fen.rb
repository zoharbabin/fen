cask "fen" do
  version "0.7.3"
  sha256 "2d48e7762a8c5899d727b3e8a1f726b6467460d3f586269b4722aeb5fa3dca28"

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
