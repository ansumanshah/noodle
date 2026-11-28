#!/bin/bash
# Refreshes app/Sources/NoodleApp/Resources/Localizable.xcstrings from the code. Idempotent: run it after adding or
# changing user-facing text. The compiler emits every localizable literal (SwiftUI and String(localized:)), then
# xcstringstool merges them into the catalog and marks keys no longer used as stale.
set -euo pipefail
cd "$(dirname "$0")/../app"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# BUILD_CMD can wrap the build, for example "nice swift build". A separate scratch path forces a full compile.
${BUILD_CMD:-swift build} --scratch-path "$out/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$out/data" >/dev/null
find "$out/build" -name '*.stringsdata' -path '*NoodleApp.build*' > "$out/files"
xargs xcrun xcstringstool sync Sources/NoodleApp/Resources/Localizable.xcstrings --stringsdata < "$out/files"
