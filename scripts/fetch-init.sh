#!/usr/bin/env bash
# Tini v0.19.0 static Linux arm64, MIT: https://github.com/krallin/tini/releases/tag/v0.19.0
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/build/tools/tini-static-arm64"
sha=eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9
mkdir -p "$(dirname "$dest")"
if [[ -f $dest && $(shasum -a 256 "$dest" | awk '{print $1}') == "$sha" ]]; then exit 0; fi
tmp=$(mktemp "${TMPDIR:-/tmp}/noodle-tini.XXXXXX")
trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error --location --retry 3 -o "$tmp" \
  https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-arm64
[[ $(shasum -a 256 "$tmp" | awk '{print $1}') == "$sha" ]] || { echo 'fetch-init: SHA-256 mismatch' >&2; exit 1; }
install -m 0755 "$tmp" "$dest.tmp.$$"
mv -f "$dest.tmp.$$" "$dest"
