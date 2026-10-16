cask "fen" do
  version "0.7.2"
  sha256 "a65fe2ed7623158f2396a2e695cda943ebb0cce7cce0993379e35f848d3b7c40"

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
