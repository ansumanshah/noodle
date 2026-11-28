The cask lives here and is copied to the tap repo. The tap is `ansumanshah/homebrew-tap`.
Per release: `packaging/homebrew/update-cask.sh build/release/<v>/Noodle-<v>.dmg`, copy `Casks/noodle.rb` to the tap's `Casks/`, commit and push.
Users install with `brew install --cask ansumanshah/tap/noodle`.
