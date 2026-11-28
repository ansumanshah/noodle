#!/usr/bin/env bash
# Produce Metadata.appintents for the SwiftPM-built app (Xcode normally does this step).
# Usage: extract-appintents.sh <app build dir holding NoodleApp.build> <output dir>
# The app must be built with the flags in scripts/make-app.sh (const values on, protocols file).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=$1 out=$2
list=$(mktemp) sources=$(mktemp)
trap 'rm -f "$list" "$sources"' EXIT
find "$build" -path '*/Release/*' -path '*NoodleApp*.build*' -name '*.swiftconstvalues' > "$list"
[[ -s $list ]] || { echo "extract-appintents: no .swiftconstvalues under $build" >&2; exit 1; }
find "$root/app/Sources/NoodleApp" -name '*.swift' > "$sources"
mkdir -p "$out"
xcrun appintentsmetadataprocessor --output "$out" \
  --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" --module-name NoodleApp \
  --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build/{print $3}')" \
  --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macos26.0 \
  --source-file-list "$sources" --swift-const-vals-list "$list" --quiet-warnings 2>&1 | grep -v "^20" || true
[[ -f $out/Metadata.appintents/extract.actionsdata ]] || { echo "extract-appintents: no metadata written" >&2; exit 1; }
