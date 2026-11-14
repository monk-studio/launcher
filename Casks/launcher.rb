cask "launcher" do
  version "1.0"
  sha256 "10a085972c88ff363c6d4aa94fb2e744fd48335978e112e86246b121268dcb9e"

  url "https://gitlab.com/wddwycc/launcher/-/releases/v#{version}/downloads/Launcher-#{version}.zip"
  name "Launcher"
  desc "Native Spotlight replacement with Keep Awake"
  homepage "https://gitlab.com/wddwycc/launcher"

  livecheck do
    url "https://gitlab.com/wddwycc/launcher.git"
    strategy :git
  end

  depends_on macos: :ventura

  app "Launcher.app"

  uninstall quit: "studio.monk.launcher"

  caveats <<~EOS
    To use ⌘Space, turn off Spotlight's shortcut:
      System Settings → Keyboard → Keyboard Shortcuts → Spotlight
      uncheck "Show Spotlight search"
  EOS
end
