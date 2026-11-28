cask "noodle" do
  version "26.11.8"
  sha256 "71c3b3da9bbc17308abe45cb1150666993f51afd73dbc9c29228f0789e3817ec" # set by update-cask.sh

  url "https://github.com/ansumanshah/noodle/releases/download/v#{version}/Noodle-#{version}.dmg"
  name "Noodle"
  desc "Docker-compatible container runtime and local models for macOS"
  homepage "https://getnoodle.dev"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Noodle.app"
  binary "#{appdir}/Noodle.app/Contents/Helpers/noodle"

  uninstall quit: "dev.getnoodle.Noodle"

  zap trash: [
    "~/.noodle",
    "~/Library/Application Support/Noodle",
    "~/Library/LaunchAgents/dev.getnoodle.noodled.plist",
    "~/Library/LaunchAgents/dev.getnoodle.runners.plist",
    "~/Library/Preferences/dev.getnoodle.Noodle.plist",
  ]

  caveats <<~EOS
    Before removing Noodle, run `noodle uninstall` to stop the daemon and remove its
    login item. Add `--delete-data --yes` to also delete containers and images.
  EOS
end
