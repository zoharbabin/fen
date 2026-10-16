cask "fen" do
  version "0.7.1"
  sha256 "3e01b7017f37494a702354696c11ba6f033459b7a4a30d63d8aab9cbd3ff8311"

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
