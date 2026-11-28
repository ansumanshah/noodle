#!/usr/bin/env bash
# release.sh refuses to publish or verify an unnotarized release. Stubbed codesign, xcrun, security, spctl,
# hdiutil and gh on PATH: no real signing, no network, nothing published.
set -euo pipefail
unset NOODLE_SIGN_IDENTITY NOODLE_CONFIRM_PUBLISH NOODLE_RELEASE_OUT NOODLE_CONFIRM_NOTARIZE
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/noodle-release-publish.XXXXXX")
trap 'rm -rf "$work"' EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; sed 's/^/  | /' "$work/out" >&2; exit 1; }

fixture=$work/tree stub=$work/bin
mkdir -p "$fixture/scripts" "$fixture/build/Noodle.app" "$fixture/build/release/1.2.3" "$stub"
cp "$root/scripts/release.sh" "$fixture/scripts/"
: >"$fixture/build/release/1.2.3/Noodle-1.2.3.dmg"
# The other release assets, and a cask carrying the (empty) dmg's hash. No update zip: publishing must not need one.
: >"$fixture/build/release/1.2.3/Noodle-1.2.3-kernel-source.tar.gz"
: >"$fixture/build/release/1.2.3/Noodle-1.2.3-e2fsprogs-source.tar.gz"
mkdir -p "$fixture/packaging/homebrew/Casks"
cask=$fixture/packaging/homebrew/Casks/noodle.rb
printf '  sha256 "%s"\n' "$(shasum -a 256 </dev/null | awk '{print $1}')" >"$cask"

# STUB_KEYCHAIN=1 lists a Developer ID identity; STUB_DMG_SIGN=devid|adhoc|none; STUB_STAPLED=1 has a ticket.
cat >"$stub/security" <<'SH'
#!/bin/sh
[ "${STUB_KEYCHAIN:-0}" = 1 ] && echo '  1) ABC "Developer ID Application: Fixture (TEAM1)"'
echo '     1 valid identities found'
SH
cat >"$stub/codesign" <<'SH'
#!/bin/sh
case "$*" in
  *--entitlements*) echo '<key>com.apple.security.virtualization</key>' ;;
  -dvv*.dmg)
    case ${STUB_DMG_SIGN:-devid} in
      devid) echo 'Authority=Developer ID Application: Fixture (TEAM1)' >&2 ;;
      adhoc) echo 'Signature=adhoc' >&2 ;;
      none) echo 'code object is not signed at all' >&2; exit 1 ;;
    esac ;;
  -dvv*) echo 'flags=0x10000(runtime)' >&2 ;;
esac
exit 0
SH
cat >"$stub/xcrun" <<'SH'
#!/bin/sh
[ "$1 $2" = "stapler validate" ] && [ "${STUB_STAPLED:-0}" != 1 ] && exit 65
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$stub/spctl"
printf '#!/bin/sh\nexit 0\n' >"$stub/hdiutil"
printf '#!/bin/sh\ntouch "%s/gh-called"\n' "$work" >"$stub/gh"
chmod +x "$stub"/*

run() { # expected-exit args... (env already set by the caller)
  local want=$1 got=0; shift
  PATH="$stub:$PATH" NOODLE_VERSION=1.2.3 NOODLE_BUILD=1 bash "$fixture/scripts/release.sh" "$@" >"$work/out" 2>&1 || got=$?
  [[ $got == "$want" ]] || { echo "exit $got, want $want: release.sh $*" >>"$work/out"; return 1; }
}
devid="Developer ID Application: Fixture (TEAM1)"

NOODLE_SIGN_IDENTITY=- run 1 github && grep -q 'ad hoc' "$work/out" || fail "github refuses an ad hoc identity"
ok "github refuses an ad hoc identity"
NOODLE_SIGN_IDENTITY=$devid STUB_DMG_SIGN=adhoc STUB_STAPLED=1 run 1 github && grep -q 'not Developer ID signed' "$work/out" || fail "github refuses an ad hoc signed dmg"
ok "github refuses an ad hoc signed dmg"
NOODLE_SIGN_IDENTITY=$devid STUB_DMG_SIGN=none STUB_STAPLED=1 run 1 github && grep -q 'not signed' "$work/out" || fail "github refuses an unsigned dmg"
ok "github refuses an unsigned dmg"
NOODLE_SIGN_IDENTITY=$devid run 1 github && grep -q 'no stapled notarization ticket' "$work/out" || fail "github refuses a dmg without a ticket"
ok "github refuses a dmg without a ticket"
NOODLE_SIGN_IDENTITY=$devid STUB_STAPLED=1 run 0 github && grep -q 'dry run' "$work/out" || fail "github dry run passes for a notarized dmg"
ok "github dry run passes for a notarized dmg"
NOODLE_SIGN_IDENTITY=$devid STUB_STAPLED=1 NOODLE_CONFIRM_PUBLISH=1 run 0 github && [[ -f $work/gh-called ]] || fail "github publishes a notarized dmg when confirmed"
ok "github publishes a notarized dmg when confirmed (stub gh)"
rm -f "$work/gh-called"
printf '  sha256 "%064d"\n' 0 >"$cask.zero"; mv "$cask" "$cask.good"; mv "$cask.zero" "$cask"
NOODLE_SIGN_IDENTITY=$devid STUB_STAPLED=1 NOODLE_CONFIRM_PUBLISH=1 run 1 github && grep -q 'cask sha256 does not match' "$work/out" && [[ ! -f $work/gh-called ]] || fail "github refuses a cask whose hash is not the dmg's"
ok "github refuses a cask whose hash is not the dmg's"
mv "$cask.good" "$cask"
NOODLE_SIGN_IDENTITY=- NOODLE_CONFIRM_PUBLISH=1 run 1 github && [[ ! -f $work/gh-called ]] || fail "confirmed github still refuses ad hoc"
ok "confirmed github still refuses ad hoc"

NOODLE_SIGN_IDENTITY=$devid run 1 verify && grep -q 'notarization ticket: NONE' "$work/out" || fail "verify fails without a ticket"
ok "verify fails without a ticket"
NOODLE_SIGN_IDENTITY=$devid STUB_STAPLED=1 run 0 verify || fail "verify passes with a ticket"
ok "verify passes with a ticket"
NOODLE_SIGN_IDENTITY=- run 0 verify --dev && grep -q 'dev build' "$work/out" || fail "verify --dev passes without a ticket"
ok "verify --dev passes without a ticket"

# No identity set and none in the keychain: only plan, lite and verify --dev fall back to ad hoc.
run 1 build && grep -q 'NOODLE_SIGN_IDENTITY=-' "$work/out" || fail "build refuses the silent ad hoc fallback"
ok "build refuses the silent ad hoc fallback"
run 1 github && grep -q 'no Developer ID' "$work/out" || fail "github refuses the silent ad hoc fallback"
ok "github refuses the silent ad hoc fallback"
run 0 plan && grep -q 'ad hoc' "$work/out" || fail "plan shows the ad hoc fallback"
ok "plan shows the ad hoc fallback"
run 0 verify --dev || fail "verify --dev falls back to ad hoc"
ok "verify --dev falls back to ad hoc"
STUB_KEYCHAIN=1 run 0 plan && grep -q "identity:  $devid" "$work/out" || fail "keychain Developer ID is picked"
ok "keychain Developer ID is picked"
echo "release-publish: $pass passed"
