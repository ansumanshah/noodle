#!/usr/bin/env bash
# Capture the website's product screens from the app's demo mode, headless: no window is fronted or activated.
# Usage: just app && scripts/capture-site-shots.sh [name...]   (names: containers models runners overview)
# The window is 1060x600 pt, close to the card's shape, so it fills the card and its text reads at README width.
# Writes website/public/media/<name>-{light,dark}.webp, framed by scripts/frame-shot.sh (gradient card, window shadow). Look at every frame before committing.
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/Noodle.app/Contents/MacOS/Noodle
out=website/public/media
work=$(mktemp -d)
trap 'pkill -f "$work/home" 2>/dev/null || true; rm -rf "$work"' EXIT
[[ -x $app ]] || { echo "build the app first: just app" >&2; exit 1; }
mkdir -p "$out"

# Window number for a pid, from CGWindowList. Compiled once per run.
cat > "$work/winid.swift" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
func area(_ w: [String: Any]) -> Double { let b = w[kCGWindowBounds as String] as? [String: Double]; return (b?["Width"] ?? 0) * (b?["Height"] ?? 0) }
let win = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .max { area($0) < area($1) }
if let n = win?[kCGWindowNumber as String] as? Int { print(n) }
SWIFT
swiftc -O -o "$work/winid" "$work/winid.swift" 2>/dev/null

# name -> demo arguments. --demo-healthy keeps every shop container running and logs free of errors.
args_for() {
  case $1 in
    containers) echo "--demo --demo-healthy --open-container=shop-api-1" ;;
    models) echo "--demo --demo-healthy --open-route=chat --demo-models=running" ;;
    runners) echo "--demo --demo-healthy --open-route=runners" ;;
    overview) echo "--demo --demo-healthy --open-route=overview" ;;
    *) echo "unknown shot: $1" >&2; exit 2 ;;
  esac
}

capture() { # name mode
  local name=$1 mode=$2 home="$work/home-$1-$2" pid id best="" bestdiff=""
  mkdir -p "$home"
  local light=(); [[ $mode == light ]] && light=(NOODLE_DEMO_LIGHT=1)
  # shellcheck disable=SC2046
  env HOME="$home" NOODLE_NO_ACTIVATE=1 ${light[@]+"${light[@]}"} "$app" $(args_for "$name") --demo-size=1060x600 >/dev/null 2>&1 &
  pid=$!
  sleep 8
  id=$("$work/winid" "$pid")
  [[ -n $id ]] || { echo "no window for $name $mode" >&2; kill "$pid"; return 1; }
  # Demo stats keep moving: take a burst and keep the frame closest to its neighbour.
  for i in $(seq -w 1 10); do screencapture -x -o -l"$id" "$work/$name-$mode-$i.png"; sleep 0.15; done
  kill "$pid" 2>/dev/null || true
  for i in $(seq -w 2 10); do
    local prev; prev=$(printf '%02d' $((10#$i - 1)))
    local d; d=$(compare -metric AE "$work/$name-$mode-$prev.png" "$work/$name-$mode-$i.png" null: 2>&1 | cut -d' ' -f1 || true)
    if [[ -z $bestdiff ]] || (( ${d%.*} < ${bestdiff%.*} )); then bestdiff=$d; best=$i; fi
  done
  scripts/frame-shot.sh "$work/$name-$mode-$best.png" "$name" "$out/$name-$mode.webp" "$mode"
  echo "$out/$name-$mode.webp (frame $best, $bestdiff pixels changed)"
}

names=("$@"); [[ ${#names[@]} -gt 0 ]] || names=(containers models runners)
for n in "${names[@]}"; do for m in light dark; do capture "$n" "$m"; done; done
