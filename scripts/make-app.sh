#!/usr/bin/env bash
# Assemble build/Noodle.app from release builds.
#
#   Contents/MacOS/Noodle      SwiftUI app with macOS guest virtualization (product NoodleApp)
#   Contents/MacOS/noodled     headless daemon, carries com.apple.security.virtualization
#   Contents/Helpers/noodle    CLI           (own folder: APFS is case-insensitive, so
#                                             Noodle and noodle cannot share a directory)
#   Contents/Resources/{vmlinux,initramfs.cpio.gz}
#
# Environment:
#   NOODLE_BIN_DIR    use prebuilt engine binaries; also use NoodleApp here if present
#   NOODLE_APP_BIN_DIR use prebuilt app binary from this dir
#   NOODLE_VERSION    CFBundleShortVersionString (default from app/Resources/Info.plist)
#   NOODLE_BUILD      CFBundleVersion (default from app/Resources/Info.plist)
#   NOODLE_PUBLIC_GITHUB_URL  optional public repository URL for the first-start card
#   NOODLE_KERNEL     kernel image (see scripts/stage-resources.sh)
#   NOODLE_SIGN_IDENTITY  codesign identity (default "-" = ad-hoc)
#   NOODLE_HARDENED=1     sign with the hardened runtime (required for notarization)
#   NOODLE_TIMESTAMP=1    use Apple's secure timestamp server (required for notarization; needs network)
#   NOODLE_E2FSPROGS_SOURCE  asset (default): `release.sh source` writes the e2fsprogs source archive as a
#                         release asset, published next to the DMG like the kernel source.
#                         bundle: ship the 9.6 MB archive inside the app instead.
#   NOODLE_BUILDKIT_ADAPTER  bundle (default) or download
#   NOODLE_RELEASE_URL_BASE  adapter host, default https://getnoodle.dev/releases (version appended)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
app=$root/build/Noodle.app
version=${NOODLE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/app/Resources/Info.plist")}
case ${NOODLE_BUILDKIT_ADAPTER:-bundle} in
  bundle|download) ;;
  *) echo "make-app: NOODLE_BUILDKIT_ADAPTER must be bundle or download" >&2; exit 1 ;;
esac
identity=${NOODLE_SIGN_IDENTITY:--}
sign_flags=(--force --sign "$identity")
[[ ${NOODLE_HARDENED:-0} == 1 ]] && sign_flags+=(--options runtime)
if [[ ${NOODLE_TIMESTAMP:-0} == 1 ]]; then sign_flags+=(--timestamp); else sign_flags+=(--timestamp=none); fi

# Engine build, app build and resource staging touch disjoint outputs, so they run side by side.
pids=()
if [[ -n ${NOODLE_BIN_DIR:-} ]]; then
  engine_bin=$NOODLE_BIN_DIR
else
  swift build -c release & pids+=($!)
  # engine_bin is resolved after the wait: --show-bin-path would block on the build lock.
  build_engine=1
fi
if [[ -n ${NOODLE_APP_BIN_DIR:-} ]]; then
  app_bin=$NOODLE_APP_BIN_DIR
elif [[ -n ${NOODLE_BIN_DIR:-} && -x $NOODLE_BIN_DIR/NoodleApp ]]; then
  app_bin=$NOODLE_BIN_DIR
else
  # Const values feed the App Intents metadata extractor (scripts/extract-appintents.sh).
  swift build --package-path "$root/app" -c release --product NoodleApp \
    -Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
    -Xswiftc -Xfrontend -Xswiftc "$root/scripts/appintents-protocols.json" & pids+=($!)
  build_app=1
fi
(
  # Never ship a stale zig-out: rebuild both guest PID 1s (init, machine). The shared zig cache makes this cheap.
  (cd "$root/guest/agent" && "$root/scripts/zig.sh" build) || { echo "make-app: guest agent build failed" >&2; exit 1; }
  NOODLE_RESOURCES_OUT=$root/build/resources "$root/scripts/stage-resources.sh"
  "$root/scripts/mkinitramfs" -i "$root/guest/agent/zig-out/bin/machine" \
    -o "$root/build/resources/machine-initramfs.cpio"
) & pids+=($!)
for pid in "${pids[@]}"; do wait "$pid"; done
[[ -z ${build_engine:-} ]] || engine_bin=$(swift build -c release --show-bin-path)
[[ -z ${build_app:-} ]] || app_bin=$(swift build --package-path "$root/app" -c release --show-bin-path)
for b in noodled noodle noodle-machine; do
  [[ -x $engine_bin/$b ]] || { echo "make-app: missing $engine_bin/$b" >&2; exit 1; }
done
[[ -x $app_bin/NoodleApp ]] || { echo "make-app: missing $app_bin/NoodleApp" >&2; exit 1; }

bash "$root/scripts/gen-notice.sh" --check

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp -c "$app_bin/NoodleApp" "$app/Contents/MacOS/Noodle"
cp -c "$engine_bin/noodled" "$app/Contents/MacOS/noodled"
cp -c "$engine_bin/noodle-machine" "$app/Contents/MacOS/noodle-machine"
cp -c "$engine_bin/noodle" "$app/Contents/Helpers/noodle"
cp -c "$root/build/resources/BuildKitAdapter-Licenses.txt" "$app/Contents/Resources/"
if [[ ${NOODLE_BUILDKIT_ADAPTER:-bundle} == bundle ]]; then
  cp -c "$root/build/resources/noodle-buildkit-adapter" "$app/Contents/Helpers/"
else
  adapter_file=Noodle-$version-buildkit-darwin-arm64.tar.gz
  adapter_archive=${NOODLE_RELEASE_OUT:-$root/build/release}/$version/$adapter_file
  NOODLE_SIGN_IDENTITY=$identity "$root/scripts/build-buildkit-adapter.sh" "$root/build/resources" --archive "$adapter_archive"
  adapter_base=${NOODLE_RELEASE_URL_BASE:-https://getnoodle.dev/releases}
  python3 - "$version" "${adapter_base%/}/$version/$adapter_file" "$adapter_archive" "$app/Contents/Resources/on-demand.json" <<'PY'
import hashlib, json, os, sys
version, url, archive, manifest = sys.argv[1:]
with open(archive, 'rb') as source:
    sha256 = hashlib.sha256(source.read()).hexdigest()
with open(manifest, 'w') as output:
    json.dump({'buildkit': {'version': version, 'url': url, 'size': os.path.getsize(archive), 'sha256': sha256}}, output, indent=2)
    output.write('\n')
PY
fi
case ${NOODLE_E2FSPROGS_SOURCE:-asset} in
  bundle|asset) ;;
  *) echo "make-app: NOODLE_E2FSPROGS_SOURCE must be bundle or asset" >&2; exit 1 ;;
esac
boot_files=(vmlinux initramfs.cpio.gz machine-initramfs.cpio.gz mke2fs e2fsck tune2fs mke2fs.conf)
[[ ${NOODLE_E2FSPROGS_SOURCE:-asset} == bundle ]] && boot_files+=(e2fsprogs-1.47.4.tar.gz)
for f in "${boot_files[@]}"; do
  [[ -f $root/build/resources/$f ]] || { echo "make-app: missing $root/build/resources/$f" >&2; exit 1; }
  cp -c "$root/build/resources/$f" "$app/Contents/Resources/$f"
done
if [[ -n ${build_app:-} ]]; then
  "$root/scripts/extract-appintents.sh" "$root/app/.build" "$app/Contents/Resources"
fi
cp "$root/NOTICE" "$app/Contents/Resources/NOTICE"
cp "$root/app/Sources/NoodleApp/Resources/apps.json" "$app/Contents/Resources/apps.json"
cp "$root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$root/build/resources/NOTICE" "$app/Contents/Resources/e2fsprogs-NOTICE"
cp "$root/app/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/app/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
xcrun actool "$root/app/Resources/Assets.xcassets" --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 26.0 --target-device mac \
  --output-format human-readable-text
if [[ -n ${NOODLE_VERSION:-} ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NOODLE_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n ${NOODLE_BUILD:-} ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NOODLE_BUILD" "$app/Contents/Info.plist"
fi
if [[ -n ${NOODLE_PUBLIC_GITHUB_URL:-} ]]; then
  plutil -replace NoodlePublicGitHubURL -string "$NOODLE_PUBLIC_GITHUB_URL" "$app/Contents/Info.plist"
fi
printf 'APPL????' >"$app/Contents/PkgInfo"

# Symbols are dead weight in shipped binaries. Full strip (what Xcode does for app targets) also drops the
# global symbol table: 2.2 MB across the app, noodled and CLI. Swift metadata lives in sections, not the symtab.
# Do this before signing.
for b in "$app/Contents/MacOS/noodle-machine" "$app/Contents/MacOS/noodled" "$app/Contents/MacOS/Noodle" "$app/Contents/Helpers/noodle"; do strip "$b" 2>/dev/null; done
# The e2fsprogs tools are built without a strip step; the bundle copies lose their local symbols too.
for t in mke2fs e2fsck tune2fs; do strip "$app/Contents/Resources/$t" 2>/dev/null; done

# Inner code first, each with its own entitlements; the bundle seal goes last.
# No --deep: it would re-sign noodled and drop the virtualization entitlement.
for tool in mke2fs e2fsck tune2fs; do
  codesign "${sign_flags[@]}" "$app/Contents/Resources/$tool"
done
codesign "${sign_flags[@]}" \
  --entitlements "$root/Resources/noodled.entitlements" "$app/Contents/MacOS/noodled"
codesign "${sign_flags[@]}" \
  --entitlements "$root/Resources/noodled.entitlements" "$app/Contents/MacOS/noodle-machine"
codesign "${sign_flags[@]}" "$app/Contents/Helpers/noodle"
if [[ ${NOODLE_BUILDKIT_ADAPTER:-bundle} == bundle ]]; then
  codesign "${sign_flags[@]}" "$app/Contents/Helpers/noodle-buildkit-adapter"
fi
codesign "${sign_flags[@]}" \
  --entitlements "$root/Resources/noodled.entitlements" "$app/Contents/MacOS/Noodle"
codesign "${sign_flags[@]}" --entitlements "$root/Resources/noodled.entitlements" "$app"

codesign --verify --strict --verbose=1 "$app"
for executable in Noodle noodled noodle-machine; do
  if ! grep -q 'com.apple.security.virtualization' <<<"$(codesign -d --entitlements - "$app/Contents/MacOS/$executable" 2>/dev/null)"; then
    echo "make-app: $executable lost its virtualization entitlement" >&2
    exit 1
  fi
done

echo "make-app: $app"
du -sh "$app" | awk '{print "make-app: size " $1}'
find "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" -type f -exec ls -l {} + || true
