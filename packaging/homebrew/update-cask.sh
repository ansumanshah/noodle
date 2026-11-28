#!/usr/bin/env bash
# Usage: update-cask.sh <Noodle-X.Y.Z.dmg>  Sets the cask's sha256 (and version, from the file name).
set -euo pipefail
dmg=${1:?usage: $0 <dmg>}
[[ -f $dmg ]] || { echo "no such file: $dmg" >&2; exit 1; }
cask=$(dirname "$0")/Casks/noodle.rb
sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
version=$(basename "$dmg" | sed -E 's/^Noodle-([0-9][^ ]*)\.dmg$/\1/')
[[ $version != "$(basename "$dmg")" ]] || { echo "dmg must be named Noodle-<version>.dmg" >&2; exit 1; }
sed -i '' -E "s/^  version \".*\"/  version \"$version\"/; s/^  sha256 \"[0-9a-f]+\"/  sha256 \"$sha\"/" "$cask"
echo "$cask: version $version sha256 $sha"
