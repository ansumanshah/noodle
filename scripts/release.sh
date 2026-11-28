#!/usr/bin/env bash
# Release pipeline up to, but not including, any Apple submission.
#
#   scripts/release.sh plan        show the identity, version and output paths; builds nothing
#   scripts/release.sh build       release build + hardened-runtime signing -> build/Noodle.app
#   scripts/release.sh dmg         build/release/<version>/Noodle-<version>.dmg (signed when a real identity is set)
#   scripts/release.sh source      matching kernel and e2fsprogs source assets (required by dmg/feed)
#   scripts/release.sh lite        explain why all remaining bundled parts are required
#   scripts/release.sh feed        update zip + signed arm64/appcast.json (needs NOODLE_UPDATE_KEY_FILE)
#   scripts/release.sh verify      codesign, spctl and stapled-ticket checks; fails without a notarization ticket
#   scripts/release.sh verify --dev  same checks for a dev or pre-notarization build: a missing ticket is reported, not fatal
#   scripts/release.sh github      print (or with NOODLE_CONFIRM_PUBLISH=1 run) gh release create for build/release/<version>;
#                                  refuses unless the dmg is Developer ID signed and has a stapled ticket
#   scripts/release.sh notarize    EXPLICIT: submits the dmg to Apple and staples. Never run by other steps.
#   scripts/release.sh all         build, dmg, feed, verify --dev (no notarize)
#
# Environment:
#   NOODLE_SIGN_IDENTITY  "-" for ad hoc; unset = first "Developer ID Application" identity in the keychain.
#                         With none found, only plan, lite and verify --dev fall back to ad hoc; other steps refuse.
#   NOODLE_VERSION / NOODLE_BUILD   version and integer build (default from app/Resources/Info.plist)
#   NOODLE_BIN_DIR        prebuilt engine binaries, passed to make-app.sh
#   NOODLE_APP_BIN_DIR    prebuilt app binary, passed to make-app.sh
#   NOODLE_UPDATE_KEY_FILE   Ed25519 private key from `swift scripts/update-sign.swift keygen`
#   NOODLE_UPDATE_URL_BASE   where the zip will be hosted (default: the feed base in Info.plist)
#   NOODLE_CONFIRM_NOTARIZE=1  second key to turn for notarize
#   NOODLE_RELEASE_OUT    output root (default build/release)
#   NOODLE_RELEASE_URL_BASE  adapter host when downloaded (make-app default: getnoodle.dev, not live for 26.11.1)
#   NOODLE_BUILDKIT_ADAPTER  bundle (default here: 26.11.1 has no live download host) or download
#   NOODLE_CONFIRM_PUBLISH=1 let `github` actually run gh release create
set -euo pipefail
export NOODLE_BUILDKIT_ADAPTER=${NOODLE_BUILDKIT_ADAPTER:-bundle}

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
plist=$root/app/Resources/Info.plist
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
version=${NOODLE_VERSION:-$(pb CFBundleShortVersionString)}
build=${NOODLE_BUILD:-$(pb CFBundleVersion)}
arch=arm64
out=${NOODLE_RELEASE_OUT:-$root/build/release}/$version
app=$root/build/Noodle.app
dmg=$out/Noodle-$version.dmg
zip=$out/$arch/Noodle-$version-$arch.zip
source_asset=$out/Noodle-$version-kernel-source.tar.gz
e2fs_asset=$out/Noodle-$version-e2fsprogs-source.tar.gz
adapter_asset=$out/Noodle-$version-buildkit-darwin-arm64.tar.gz

identity=${NOODLE_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  identity=$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$identities")
  if [[ -z $identity ]]; then
    case "${1:-plan} ${2:-}" in
      plan*|lite*|dmg-lite*|"verify --dev") identity=- ;;
      *) echo "release: no Developer ID Application identity in the keychain; set NOODLE_SIGN_IDENTITY=- for an ad hoc dev build" >&2; exit 1 ;;
    esac
  fi
fi
real_identity() { [[ $identity != - ]]; }

cmd_plan() {
  echo "version:   $version (build $build)"
  echo "identity:  $identity$(real_identity || echo ' (ad hoc: dev only, Gatekeeper will reject)')"
  echo "hardened:  yes   timestamp: $(real_identity && echo secure || echo none)"
  echo "app:       $app"
  echo "dmg:       $dmg"
  echo "feed:      $out/$arch/appcast.json"
  echo "source:    $source_asset"
  if [[ ${NOODLE_E2FSPROGS_SOURCE:-asset} == asset ]]; then echo "e2fsprogs: $e2fs_asset (not bundled in the app)"; fi
  if [[ ${NOODLE_BUILDKIT_ADAPTER} != bundle ]]; then echo "adapter:   $adapter_asset (not bundled in the app)"; fi
}

cmd_build() {
  NOODLE_SIGN_IDENTITY=$identity NOODLE_VERSION=$version NOODLE_BUILD=$build NOODLE_HARDENED=1 \
    NOODLE_TIMESTAMP=$(real_identity && echo 1 || echo 0) scripts/make-app.sh
}

# make-app builds this asset before sealing its pin. Repackaging it here could change
# the signature timestamp and break the pin in the already-signed app.
check_adapter_asset() {
  if [[ -f $app/Contents/Resources/on-demand.json ]]; then
    python3 - "$app/Contents/Resources/on-demand.json" "$adapter_asset" "$version" <<'PY'
import hashlib, json, os, sys
manifest, archive, version = sys.argv[1:]
with open(manifest) as source:
    pin = json.load(source)['buildkit']
try:
    with open(archive, 'rb') as source:
        digest = hashlib.sha256(source.read()).hexdigest()
    valid = pin['version'] == version and pin['size'] == os.path.getsize(archive) and pin['sha256'] == digest
except FileNotFoundError:
    valid = False
if not valid:
    sys.exit('release: adapter asset does not match the sealed app manifest; run release.sh build again')
PY
    echo "release: $adapter_asset (publish alongside every DMG and update zip)"
  elif [[ ! -x $app/Contents/Helpers/noodle-buildkit-adapter ]]; then
    echo "release: app has neither a bundled adapter nor an on-demand manifest; rebuild the app" >&2
    return 1
  fi
}

# Default provenance is the custom kernel build. For another kernel, require a
# prepared source directory containing full sources, actual config, build scripts,
# and kernel.sha256 (the SHA-256 of the kernel shipped in this app).
cmd_source() (
  [[ -f $app/Contents/Resources/vmlinux ]] || { echo "release: build the app before packaging its kernel source" >&2; return 1; }
  mkdir -p "$out"
  check_adapter_asset
  local stage kernel_hash recorded
  stage=$(mktemp -d "${TMPDIR:-/tmp}/noodle-source.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  kernel_hash=$(shasum -a 256 "$app/Contents/Resources/vmlinux" | awk '{print $1}')
  if [[ -n ${NOODLE_KERNEL_SOURCE_DIR:-} ]]; then
    for required in kernel.sha256 config build.sh; do
      [[ -s $NOODLE_KERNEL_SOURCE_DIR/$required ]] || { echo "release: source directory missing $required" >&2; return 1; }
    done
    [[ -d $NOODLE_KERNEL_SOURCE_DIR/linux && -f $NOODLE_KERNEL_SOURCE_DIR/linux/Makefile ]] || {
      echo "release: source directory must contain complete matching Linux sources in linux/" >&2; return 1;
    }
    recorded=$(awk 'NR == 1 {print $1}' "$NOODLE_KERNEL_SOURCE_DIR/kernel.sha256")
    [[ $recorded == "$kernel_hash" ]] || { echo "release: source provenance does not match bundled kernel" >&2; return 1; }
    cp -R "$NOODLE_KERNEL_SOURCE_DIR/." "$stage/"
  else
    local kver=${KERNEL_VERSION:-6.18.63} archive
    archive=$root/build/kernel-src/linux-$kver.tar.xz
    for required in "$archive" "$root/build/kernel/config" "$root/build/kernel/vmlinux"; do
      [[ -s $required ]] || { echo "release: missing $required; build the custom kernel or set NOODLE_KERNEL_SOURCE_DIR" >&2; return 1; }
    done
    recorded=$(shasum -a 256 "$root/build/kernel/vmlinux" | awk '{print $1}')
    [[ $recorded == "$kernel_hash" ]] || { echo "release: bundled kernel differs from build/kernel/vmlinux; provide its matching source directory" >&2; return 1; }
    grep -q "Linux/arm64 $kver Kernel Configuration" "$root/build/kernel/config" || { echo "release: build/kernel/config is not Linux $kver; rebuild the kernel or set KERNEL_VERSION" >&2; return 1; }
    cp "$archive" "$stage/"
    cp "$root/build/kernel/config" "$stage/config"
    mkdir -p "$stage/scripts" "$stage/Resources/kernel"
    cp "$root/scripts/build-kernel.sh" "$stage/scripts/"
    cp "$root/Resources/kernel/noodle.config" "$stage/Resources/kernel/"
    if [[ -d $root/Resources/kernel/patches ]]; then
      cp -R "$root/Resources/kernel/patches" "$stage/Resources/kernel/"
    fi
    printf '%s\n' "$kernel_hash" >"$stage/kernel.sha256"
    cat >"$stage/build.sh" <<BUILD
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\$0")"
tar -xf linux-$kver.tar.xz
cp config linux-$kver/.config
cd linux-$kver
for patch_file in ../Resources/kernel/patches/*.patch; do
  [[ -f \$patch_file ]] || continue
  patch -p1 --fuzz=0 <"\$patch_file"
done
make ARCH=arm64 olddefconfig
make ARCH=arm64 -j"\${JOBS:-4}" Image
BUILD
    chmod +x "$stage/build.sh"
  fi
  tar -czf "$source_asset.tmp" -C "$stage" .
  mv "$source_asset.tmp" "$source_asset"
  echo "release: $source_asset (publish alongside every DMG and update zip)"
  # The e2fsprogs source travels one way or the other: inside the app, or as an asset beside it. Never neither.
  local bundled=$app/Contents/Resources/e2fsprogs-1.47.4.tar.gz
  rm -f "$e2fs_asset"
  if [[ ${NOODLE_E2FSPROGS_SOURCE:-asset} == asset ]]; then
    local e2src=$root/build/tools/e2fsprogs-1.47.4.tar.gz
    [[ -s $e2src ]] || { echo "release: missing e2fsprogs source archive $e2src" >&2; return 1; }
    if [[ -e $bundled ]]; then
      echo "release: app still bundles the e2fsprogs source; rebuild with NOODLE_E2FSPROGS_SOURCE=asset" >&2
      return 1
    fi
    cp "$e2src" "$e2fs_asset"
    chmod 644 "$e2fs_asset"
    echo "release: $e2fs_asset (publish alongside every DMG and update zip)"
  elif [[ ! -s $bundled ]]; then
    echo "release: NOODLE_E2FSPROGS_SOURCE=bundle but the app has no e2fsprogs source; rebuild the app with the same setting" >&2
    return 1
  fi
)

cmd_lite() {
  echo "release: the standard DMG downloads Docker, Compose, Buildx, BuildKit, its native build adapter, Grype, Syft and cloudflared on demand."
  echo "release: the remaining boot files, machine helper and filesystem tools have no release fetch path; omitting them breaks supported commands."
  echo "release: use dmg for the complete app."
}

cmd_dmg() (
  [[ -d $app ]] || { echo "release: $app missing, run build first" >&2; exit 1; }
  cmd_source
  local stage
  stage=$(mktemp -d "${TMPDIR:-/tmp}/noodle-dmg.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  cp -cR "$app" "$stage/Noodle.app"
  ln -s /Applications "$stage/Applications"
  rm -f "$dmg"
  hdiutil create -quiet -volname "Noodle $version" -srcfolder "$stage" -fs APFS -format ULMO "$dmg"
  if real_identity; then codesign --force --sign "$identity" --timestamp "$dmg"; fi
  echo "release: $dmg ($(du -h "$dmg" | awk '{print $1}'))"
)

cmd_feed() {
  [[ -d $app ]] || { echo "release: $app missing, run build first" >&2; exit 1; }
  cmd_source
  : "${NOODLE_UPDATE_KEY_FILE:?set NOODLE_UPDATE_KEY_FILE to the release key}"
  mkdir -p "$out/$arch"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  # The zip is a GitHub release asset; only the small signed appcast.json lives at the feed base.
  local url=${NOODLE_UPDATE_ZIP_URL:-https://github.com/ansumanshah/noodle/releases/download/v$version/$(basename "$zip")}
  swift scripts/update-sign.swift feed "$zip" "$NOODLE_UPDATE_KEY_FILE" "$version" "$build" "$arch" \
    "$url" >"$out/$arch/appcast.json"
  mkdir -p "website/public/updates/$arch" && cp "$out/$arch/appcast.json" "website/public/updates/$arch/appcast.json"
  echo "release: $zip"
  echo "release: $out/$arch/appcast.json (copied to website/public/updates; publish the release first, then deploy the site)"
}

cmd_verify() {
  local status=0 signature entitlements dev=0
  [[ ${1:-} == --dev ]] && dev=1
  echo "== app"
  codesign --verify --deep --strict --verbose=2 "$app" || status=1
  # Capture first: grep -q closes the pipe early, which pipefail reports as a failed check.
  # Check the producer's status too: matching output from a failed codesign must not pass.
  if signature=$(codesign -dvv "$app" 2>&1); then
    grep -E 'Identifier|Authority|TeamIdentifier|flags|Timestamp' <<<"$signature" || true
    if grep -q 'flags=.*runtime' <<<"$signature"; then echo "hardened runtime: yes"; else echo "hardened runtime: NO"; status=1; fi
  else
    printf '%s\n' "$signature" >&2
    echo "hardened runtime: NO (codesign inspection failed)"; status=1
  fi
  if entitlements=$(codesign -d --entitlements - "$app/Contents/MacOS/noodled" 2>/dev/null) && grep -q com.apple.security.virtualization <<<"$entitlements"; then
    echo "noodled virtualization entitlement: yes"
  else echo "noodled virtualization entitlement: NO"; status=1; fi
  if entitlements=$(codesign -d --entitlements - "$app/Contents/MacOS/noodle-machine" 2>/dev/null) && grep -q com.apple.security.virtualization <<<"$entitlements"; then :; else
    echo "noodle-machine virtualization entitlement: NO"; status=1
  fi
  if entitlements=$(codesign -d --entitlements - "$app" 2>/dev/null) && grep -q com.apple.security.virtualization <<<"$entitlements"; then
    echo "Noodle app virtualization entitlement: yes"
  else echo "Noodle app virtualization entitlement: NO"; status=1; fi
  echo "== gatekeeper (app)"
  if spctl --assess --type execute --verbose=2 "$app"; then :; else
    real_identity && status=1 || echo "(expected to fail for an ad hoc build)"
  fi
  if [[ -f $dmg ]]; then
    echo "== dmg"
    hdiutil verify -quiet "$dmg" && echo "dmg image: ok" || status=1
    if real_identity; then codesign --verify --strict --verbose=2 "$dmg" || status=1; fi
    if ! spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"; then
      if [[ $dev == 1 ]] || ! real_identity; then echo "(expected before notarization or for an ad hoc build)"; else status=1; fi
    fi
  fi
  if xcrun stapler validate "$dmg" >/dev/null 2>&1; then echo "notarization ticket: stapled"
  elif [[ $dev == 1 ]]; then echo "notarization ticket: none (dev build: not required)"
  else echo "notarization ticket: NONE (run notarize; verify --dev for a dev build)"; status=1; fi
  return $status
}

cmd_notarize() {
  real_identity || { echo "release: notarization needs a Developer ID identity" >&2; exit 1; }
  [[ -d $app ]] || { echo "release: $app missing, run build first" >&2; exit 1; }
  [[ ${NOODLE_CONFIRM_NOTARIZE:-0} == 1 ]] || { echo "release: set NOODLE_CONFIRM_NOTARIZE=1 to upload $app and its dmg to Apple" >&2; exit 1; }
  # Notarize the app first and staple it, so the dmg (and the update zip) carry a ticketed app.
  up=$(mktemp -d "${TMPDIR:-/tmp}/noodle-notarize.XXXXXX")
  trap 'rm -rf "$up"' EXIT
  ditto -c -k --keepParent "$app" "$up/Noodle.zip"
  xcrun notarytool submit "$up/Noodle.zip" --keychain-profile notary --wait
  xcrun stapler staple "$app"
  cmd_dmg
  xcrun notarytool submit "$dmg" --keychain-profile notary --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  # Stapling changes the dmg's bytes, so the cask hash is taken from the final dmg. Commit it before the public export is cut and tagged.
  bash packaging/homebrew/update-cask.sh "$dmg"
  echo "release: commit packaging/homebrew/Casks/noodle.rb before tagging; with an update key, run \`scripts/release.sh feed\` again so the zip carries the stapled app"
}

# Publishing needs what Gatekeeper needs: a Developer ID signature on the dmg and a stapled ticket.
check_publishable() {
  [[ -z $(git status --porcelain) ]] || { echo "release: working tree is dirty; commit or stash before publishing" >&2; return 1; }
  real_identity || { echo "release: refusing to publish an ad hoc build; set a Developer ID identity" >&2; return 1; }
  [[ -f $dmg ]] || { echo "release: $dmg missing, run dmg first" >&2; return 1; }
  local signature
  signature=$(codesign -dvv "$dmg" 2>&1) || { echo "release: $dmg is not signed" >&2; return 1; }
  if grep -q 'Signature=adhoc' <<<"$signature" || ! grep -q 'Authority=Developer ID Application' <<<"$signature"; then
    echo "release: $dmg is not Developer ID signed" >&2; return 1
  fi
  codesign --verify --strict "$dmg" || { echo "release: $dmg has no valid code signature" >&2; return 1; }
  hdiutil verify -quiet "$dmg" || { echo "release: $dmg is not a valid disk image" >&2; return 1; }
  xcrun stapler validate "$dmg" >/dev/null 2>&1 || { echo "release: $dmg has no stapled notarization ticket; run notarize first" >&2; return 1; }
  grep -q "sha256 \"$(shasum -a 256 "$dmg" | awk '{print $1}')\"" packaging/homebrew/Casks/noodle.rb || { echo "release: the cask sha256 does not match $dmg; run notarize (or update-cask.sh) and commit it" >&2; return 1; }
}

cmd_github() {
  check_publishable || exit 1
  local asset assets=("$dmg" "$source_asset" "$e2fs_asset")
  # The update zip exists only when an update key signed a feed; a release without in-app updates ships none.
  [[ ! -f $zip ]] || assets+=("$zip")
  [[ $NOODLE_BUILDKIT_ADAPTER == bundle ]] || assets+=("$adapter_asset")
  for asset in "${assets[@]}"; do [[ -f $asset ]] || { echo "release: missing asset $asset" >&2; exit 1; }; done
  local cmd=(gh release create "v$version" "${assets[@]}" --verify-tag --repo ansumanshah/noodle --title "Noodle $version" --notes-file "docs/releases/$version.md")
  if [[ ${NOODLE_CONFIRM_PUBLISH:-0} != 1 ]]; then
    echo "release: dry run. Run this (or set NOODLE_CONFIRM_PUBLISH=1):"
    printf '  %q' "${cmd[@]}"; echo
    return 0
  fi
  "${cmd[@]}"
}

case ${1:-plan} in
  plan) cmd_plan ;;
  build) cmd_build ;;
  dmg) cmd_dmg ;;
  source) cmd_source ;;
  lite|dmg-lite) cmd_lite ;;
  feed) cmd_feed ;;
  verify) cmd_verify "${2:-}" ;;
  github) cmd_github ;;
  notarize) cmd_notarize ;;
  all) cmd_build; cmd_dmg; cmd_feed; cmd_verify --dev; echo "release: notarize, then run verify before github" ;;
  *) echo "usage: scripts/release.sh plan|build|dmg|lite|source|feed|verify [--dev]|github|notarize|all" >&2; exit 2 ;;
esac
