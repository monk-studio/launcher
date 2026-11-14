cask "launcher" do
  version "1.1"
  sha256 "f261fb9e3b7d4df757fbb24c1b6c07d2b891c0aed630acf31ec56eb282dd8ae4"

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
