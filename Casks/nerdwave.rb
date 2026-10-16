cask "nerdwave" do
  version "1.7.0"
  sha256 "84cb9d13cf27b3b921f840b7cfd8e66201b6fd04b9c2008da794e2779cd62037"

  url "https://github.com/grumpitect/nerdwave/releases/download/v#{version}/Nerdwave-#{version}.zip"
  name "Nerdwave"
  desc "Menu bar background music player for streamers"
  homepage "https://github.com/grumpitect/nerdwave"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Nerdwave.app"

  uninstall quit: "com.nerdative.nerdwave"

  zap trash: [
    "~/Library/Application Support/Nerdwave",
    "~/Library/Preferences/com.nerdative.nerdwave.plist",
  ]

  caveats <<~EOS
    Nerdwave is free and not notarized by Apple. The first time you open it, macOS will say it
    can't verify the developer: open System Settings > Privacy & Security and click "Open Anyway".
    You only need to do this once.
  EOS
end
