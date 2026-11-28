#!/usr/bin/env bash
# Update flow against a local feed over real HTTP (127.0.0.1): signed feed, tampered artifact,
# wrong key, swapped architecture, downgrade, stage, install, rollback. Fake daemon only; no VM or app launch.
# Isolation: NOODLE_HOME and every app copy live under one mktemp dir; ~/.noodle and /Applications are untouched.
# Usage: NOODLE_BIN=.build/release/noodle tests/update.sh
# shellcheck disable=SC2015  # `cond && ok || fail`: ok never fails
set -euo pipefail

noodle=${NOODLE_BIN:?set NOODLE_BIN to the built noodle executable}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/noodle-update.XXXXXX)
server=''
daemon=''
cleanup() {
  if [ -n "$daemon" ]; then kill -KILL "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true; fi
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
export NOODLE_HOME=$work/home
export HOME=$work/user
mkdir -p "$HOME"
pass=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
expect_fail() { # description, expected substring, command...
  local what=$1 want=$2 got
  shift 2
  if got=$("$@" 2>&1); then fail "$what: expected failure, got: $got"; fi
  grep -qi -- "$want" <<<"$got" || fail "$what: expected '$want', got: $got"
  ok "$what"
}

make_app() { # dir version build
  local app=$1/Noodle.app
  mkdir -p "$app/Contents/MacOS"
  cp /usr/bin/true "$app/Contents/MacOS/Noodle"
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.noodle.update-fixture</string>
  <key>CFBundleName</key><string>Noodle</string>
  <key>CFBundleExecutable</key><string>Noodle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$2</string>
  <key>CFBundleVersion</key><string>$3</string>
</dict>
</plist>
PLIST
  codesign --force --sign - --timestamp=none "$app"
}
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }

mkdir -p "$work/Applications" "$work/build" "$work/feed/arm64" "$work/feed/x86_64"
make_app "$work/Applications" 0.1.0 1
make_app "$work/build" 0.2.0 2
app=$work/Applications/Noodle.app

swift "$root/scripts/update-sign.swift" keygen "$work/key" >"$work/pub"
swift "$root/scripts/update-sign.swift" keygen "$work/other-key" >"$work/other-pub"
pub=$(cat "$work/pub")
other_pub=$(cat "$work/other-pub")

zip=$work/feed/arm64/Noodle-0.2.0-arm64.zip
ditto -c -k --keepParent "$work/build/Noodle.app" "$zip"
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
base=http://127.0.0.1:$port
(cd "$work/feed" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
for _ in $(seq 50); do curl -s -o /dev/null "$base/" && break; sleep 0.1; done

sign() { swift "$root/scripts/update-sign.swift" feed "$zip" "$work/key" 0.2.0 2 "$1" "Noodle-0.2.0-arm64.zip"; }
sign arm64 >"$work/feed/arm64/appcast.json"
upd=("$noodle" update)
common=(--feed-base "$base" --public-key "$pub" --app "$app")

# 1. a genuine feed offers the update; the same build or newer is "up to date"
[[ $("${upd[@]}" check "${common[@]}" --current-build 1) == *"update available: 0.2.0"* ]] && ok "check offers 0.2.0" || fail "check"
[[ $("${upd[@]}" check "${common[@]}" --current-build 2) == *"up to date"* ]] && ok "downgrade/same build is refused" || fail "same build"

# 2. wrong release key
expect_fail "feed signed by another key is rejected" "signature" "${upd[@]}" check --feed-base "$base" --public-key "$other_pub" --current-build 1

# 3. architecture swap: an x86_64 feed served at the arm64 path
swift "$root/scripts/update-sign.swift" feed "$zip" "$work/key" 0.2.0 2 x86_64 "Noodle-0.2.0-arm64.zip" >"$work/x86.json"
cp "$work/feed/arm64/appcast.json" "$work/arm64.json"
cp "$work/x86.json" "$work/feed/arm64/appcast.json"
expect_fail "x86_64 feed at the arm64 path is rejected" "not this Mac" "${upd[@]}" check "${common[@]}" --current-build 1
cp "$work/arm64.json" "$work/feed/arm64/appcast.json"

# 4. tampered artifact (same length, one byte flipped): feed signature is fine, the hash is not
cp "$zip" "$work/zip.good"
printf '\x00' | dd of="$zip" bs=1 seek=40 count=1 conv=notrunc 2>/dev/null
expect_fail "tampered artifact is discarded" "checksum" "${upd[@]}" stage "${common[@]}" --current-build 1
[ -z "$(ls "$NOODLE_HOME/update/download" 2>/dev/null)" ] && ok "tampered download left nothing behind" || fail "download not cleaned"
[ ! -e "$NOODLE_HOME/update/state.json" ] && ok "nothing staged after tamper" || fail "state written"

# 5. truncated / extended artifact
cp "$work/zip.good" "$zip"; printf 'x' >>"$zip"
expect_fail "wrong-length artifact is rejected" "The download" "${upd[@]}" stage "${common[@]}" --current-build 1
cp "$work/zip.good" "$zip"

# 6. stage, install, roll back
"${upd[@]}" stage "${common[@]}" --current-build 1 | grep -q "staged 0.2.0" && ok "stage verifies and extracts" || fail "stage"
[ "$(version_of "$app")" = 0.1.0 ] && ok "staging does not touch the installed app" || fail "app changed while staging"

# The installed app can advance after staging, independent of the feed-time check.
cp -R "$app" "$work/original.app"
for build in 2 3; do
  rm -rf "$app"
  make_app "$work/Applications" "0.$build.0" "$build"
  expect_fail "install rejects staged build 2 over build $build" "newest version" "${upd[@]}" install --app "$app" --yes
  [ "$(version_of "$app")" = "0.$build.0" ] || fail "stale install changed the app"
done
rm -rf "$app"
cp -R "$work/original.app" "$app"

# 6b. running containers: a fake daemon on the real socket path answers GET /containers/json.
# The fixture needs a process named noodled. Some Python launchers re-exec
# Python.app, so copy the running interpreter instead of symlinking the launcher.
mkdir -p "$NOODLE_HOME/run" "$work/bin"
export NOODLE_NO_LAUNCHCTL=1
fixture_python=$(python3 -c 'import ctypes, os
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
path = ctypes.create_string_buffer(4096)
if libproc.proc_pidpath(os.getpid(), path, len(path)) <= 0:
    raise SystemExit("cannot locate the running Python interpreter")
print(os.fsdecode(path.value))')
fixture_python_home=$(python3 -c 'import sys; print(sys.base_prefix)')
cp "$fixture_python" "$work/bin/noodled"
start_daemon() {
  rm -f "$NOODLE_HOME/run/docker.sock"
  PYTHONHOME="$fixture_python_home" "$work/bin/noodled" "$work/fake-daemon.py" "$NOODLE_HOME/run/docker.sock" "$work/running" &
  daemon=$!
  for _ in $(seq 50); do [ -S "$NOODLE_HOME/run/docker.sock" ] && break; sleep 0.1; done
}
echo 2 >"$work/running"
cat >"$work/fake-daemon.py" <<'PY'
import json, os, signal, socketserver, sys
path, count = sys.argv[1], sys.argv[2]
class H(socketserver.StreamRequestHandler):
    def handle(self):
        request = self.rfile.readline().decode().split()[1]
        while self.rfile.readline().strip(): pass
        with open(count) as f: value = f.read().strip()
        failed = value == "ping-error" or (value == "error" and request != "/_ping")
        body = json.dumps({"message": "query failed"} if failed else [{"Id": str(i)} for i in range(int(value) if value.isdigit() else 0)]).encode()
        status = b"503 Unavailable" if failed else b"200 OK"
        self.wfile.write(b"HTTP/1.1 " + status + b"\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
if os.path.exists(path): os.remove(path)
if open(count).read().strip() == "stubborn": signal.signal(signal.SIGTERM, signal.SIG_IGN)
socketserver.UnixStreamServer(path, H).serve_forever()
PY
start_daemon
# Invalid installs must leave the running engine alone, including with explicit consent.
mv "$NOODLE_HOME/update/state.json" "$work/saved-state.json"
expect_fail "missing staged state leaves the engine running" "no update is staged" "${upd[@]}" install --app "$app" --yes
kill -0 "$daemon" 2>/dev/null || fail "missing state stopped the engine"
mv "$work/saved-state.json" "$NOODLE_HOME/update/state.json"
mv "$NOODLE_HOME/update/staged" "$work/saved-staged"
expect_fail "missing staged app leaves the engine running" "no update is staged" "${upd[@]}" install --app "$app" --yes
kill -0 "$daemon" 2>/dev/null || fail "missing staged app stopped the engine"
mv "$work/saved-staged" "$NOODLE_HOME/update/staged"
for build in 2 3; do
  rm -rf "$app"
  make_app "$work/Applications" "0.$build.0" "$build"
  expect_fail "stale install over build $build leaves the engine running" "newest version" "${upd[@]}" install --app "$app" --yes
  kill -0 "$daemon" 2>/dev/null || fail "stale install stopped the engine"
done
rm -rf "$app"
cp -R "$work/original.app" "$app"
mv "$app/Contents/Info.plist" "$work/saved-info.plist"
expect_fail "unreadable target build leaves the engine running" "cannot read the installed build" "${upd[@]}" install --app "$app" --yes
kill -0 "$daemon" 2>/dev/null || fail "unreadable target stopped the engine"
mv "$work/saved-info.plist" "$app/Contents/Info.plist"

# Rollback must restart through the restored helper, after the current engine exits.
mkdir -p "$app/Contents/Helpers"
cat >"$app/Contents/Helpers/noodle" <<'SH'
#!/bin/sh
[ "$1" = start ] || exit 1
if kill -0 "$(cat "$NOODLE_HOME/old-pid")" 2>/dev/null; then echo "old engine still running"; exit 1; fi
if [ -e "$NOODLE_HOME/fail-start" ]; then echo "fixture start failed"; exit 1; fi
echo old-engine-start >>"$NOODLE_HOME/helper-calls"
SH
chmod +x "$app/Contents/Helpers/noodle"
codesign --force --sign - --timestamp=none "$app/Contents/Helpers/noodle"
codesign --force --sign - --timestamp=none "$app"
expect_fail "install with 2 running containers says so and refuses without a terminal" "2 running containers will stop" "${upd[@]}" install --app "$app" </dev/null
[ "$(version_of "$app")" = 0.1.0 ] && ok "refused install left the app alone" || fail "app changed after refusal"
for failure in error ping-error; do
  echo "$failure" >"$work/running"
  expect_fail "a $failure query needs explicit confirmation" "could not check" "${upd[@]}" install --app "$app" </dev/null
  [ "$(version_of "$app")" = 0.1.0 ] || fail "failed query allowed replacement"
done
echo 0 >"$work/running"
install_code=0
install_out=$("${upd[@]}" install --app "$app" </dev/null 2>&1) || install_code=$?
[ "$install_code" = 3 ] || fail "missing restart helper should report installed with restart failure, got $install_code"
grep -q "installed 0.2.0" <<<"$install_out" && ok "install with no running containers needs no confirmation" || fail "install: $install_out"
! kill -0 "$daemon" 2>/dev/null && ok "install stopped the running engine first" || fail "engine still running after install"
grep -q "no noodle tool to start it" <<<"$install_out" && ok "a new app that cannot restart the engine says so" || fail "no restart notice: $install_out"
[ "$(version_of "$app")" = 0.2.0 ] || fail "version after install"
codesign --verify --deep --strict "$app" && ok "installed app seal is valid" || fail "seal"
"${upd[@]}" rollback --app "$app" | grep -q restored && [ "$(version_of "$app")" = 0.1.0 ] && ok "rollback restores 0.1.0" || fail "rollback"
[ "$(ls -A "$work/Applications")" = "Noodle.app" ] && ok "no stray bundles next to the app" || fail "stray files: $(ls -A "$work/Applications")"

# 7. --yes installs over running containers
# The staged helper records a start and refuses to run until the old process is gone.
mkdir -p "$work/build/Noodle.app/Contents/Helpers"
cat >"$work/build/Noodle.app/Contents/Helpers/noodle" <<'SH'
#!/bin/sh
if [ "$1" = start ]; then
  if kill -0 "$(cat "$NOODLE_HOME/old-pid")" 2>/dev/null; then echo "old engine still running"; exit 1; fi
  if [ -e "$NOODLE_HOME/fail-start" ]; then echo "fixture start failed"; exit 1; fi
  echo new-engine-start >>"$NOODLE_HOME/helper-calls"
elif [ "$1" = update ] && [ "$2" = confirm ]; then
  echo installed-helper-confirm >>"$NOODLE_HOME/helper-calls"
else
  exit 1
fi
SH
chmod +x "$work/build/Noodle.app/Contents/Helpers/noodle"
codesign --force --sign - --timestamp=none "$work/build/Noodle.app/Contents/Helpers/noodle"
codesign --force --sign - --timestamp=none "$work/build/Noodle.app"
ditto -c -k --keepParent "$work/build/Noodle.app" "$zip"
sign arm64 >"$work/feed/arm64/appcast.json"
echo 2 >"$work/running"
start_daemon
echo "$daemon" >"$NOODLE_HOME/old-pid"
"${upd[@]}" stage "${common[@]}" --current-build 1 >/dev/null
install_out=$("${upd[@]}" install --app "$app" --yes </dev/null 2>&1) || fail "install --yes: $install_out"
grep -q "installed 0.2.0" <<<"$install_out" && ok "install --yes proceeds with running containers" || fail "install --yes"
grep -q "engine restarted with the new version" <<<"$install_out" || fail "restart was not reported"
[ "$(cat "$NOODLE_HOME/helper-calls")" = new-engine-start ] && ok "new helper starts only after old engine exits" || fail "new helper was not called"
"${upd[@]}" rollback --app "$app" >/dev/null
kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true

# A daemon that refuses to exit must prevent replacement and restart.
echo stubborn >"$work/running"
start_daemon
"${upd[@]}" stage "${common[@]}" --current-build 1 >/dev/null
expect_fail "failed stop prevents replacement" "engine did not stop" "${upd[@]}" install --app "$app" --yes
[ "$(version_of "$app")" = 0.1.0 ] || fail "app replaced after failed stop"
[ "$(cat "$NOODLE_HOME/helper-calls")" = new-engine-start ] || fail "helper ran after failed stop"
kill -KILL "$daemon"; wait "$daemon" 2>/dev/null || true
daemon=''

# A restart failure is an error even though the new app was installed successfully.
echo 0 >"$work/running"
start_daemon
echo "$daemon" >"$NOODLE_HOME/old-pid"
touch "$NOODLE_HOME/fail-start"
install_code=0
install_out=$("${upd[@]}" install --app "$app" --yes 2>&1) || install_code=$?
[ "$install_code" = 3 ] || fail "restart failure must identify a completed swap, got $install_code: $install_out"
grep -q "engine did not restart" <<<"$install_out" && ok "failed restart is reported after completed swap" || fail "restart error lost"
[ "$(version_of "$app")" = 0.2.0 ] || fail "restart failure lost the installed update"
"${upd[@]}" rollback --app "$app" >/dev/null
wait "$daemon" 2>/dev/null || true; daemon=''
rm "$NOODLE_HOME/fail-start"

# No running engine means no restart. The stale fake socket is harmless.
"${upd[@]}" stage "${common[@]}" --current-build 1 >/dev/null
"${upd[@]}" install --app "$app" --yes >/dev/null
[ "$(cat "$NOODLE_HOME/helper-calls")" = new-engine-start ] && ok "stopped engine stays stopped" || fail "started a stopped engine"

# Retained CLI discovers the installed app through setup's LaunchAgent, even with old pins.
mkdir -p "$HOME/Library/LaunchAgents" "$NOODLE_HOME/tools"
cat >"$HOME/Library/LaunchAgents/dev.getnoodle.noodled.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>ProgramArguments</key><array><string>$app/Contents/MacOS/noodled</string></array></dict></plist>
PLIST
printf '#!/bin/sh\necho current-tool\n' >"$NOODLE_HOME/tools/docker"
chmod +x "$NOODLE_HOME/tools/docker"
touch "$NOODLE_HOME/tools/.docker-1.0.0"
env NOODLE_TOOLS_MIRROR="$base/no-such-mirror" "$noodle" update confirm >/dev/null
grep -q installed-helper-confirm "$NOODLE_HOME/helper-calls" && ok "retained CLI delegates confirmation to installed helper" || fail "used old helper pins"
grep -q current-tool "$NOODLE_HOME/tools/docker" && ok "retained CLI leaves tools to the installed helper" || fail "old CLI replaced tools"
rm -rf "$NOODLE_HOME/tools"
"${upd[@]}" rollback --app "$app" >/dev/null

# Rollback uses the same lifecycle and respects the recorded target, even with a different --app.
"${upd[@]}" stage "${common[@]}" --current-build 1 >/dev/null
"${upd[@]}" install --app "$app" --yes >/dev/null
echo 2 >"$work/running"
start_daemon
echo "$daemon" >"$NOODLE_HOME/old-pid"
mv "$NOODLE_HOME/update/previous" "$work/saved-previous"
expect_fail "missing rollback backup leaves the engine running" "no update is staged" "${upd[@]}" rollback --yes
kill -0 "$daemon" 2>/dev/null || fail "missing rollback backup stopped the engine"
mv "$work/saved-previous" "$NOODLE_HOME/update/previous"
expect_fail "rollback with running containers requires consent" "2 running containers will stop" "${upd[@]}" rollback </dev/null
kill -0 "$daemon" 2>/dev/null || fail "refused rollback stopped the engine"
"${upd[@]}" rollback --app "$work/unused.app" --yes >/dev/null
[ "$(version_of "$app")" = 0.1.0 ] || fail "rollback did not restore the recorded app"
! kill -0 "$daemon" 2>/dev/null || fail "rollback left the updated engine running"
[ "$(tail -n 1 "$NOODLE_HOME/helper-calls")" = old-engine-start ] && ok "rollback restarts through the restored helper after stopping" || fail "rollback used the wrong helper"
wait "$daemon" 2>/dev/null || true; daemon=''

"${upd[@]}" stage "${common[@]}" --current-build 1 >/dev/null
"${upd[@]}" install --app "$app" --yes >/dev/null
echo stubborn >"$work/running"
start_daemon
expect_fail "failed rollback stop prevents replacement" "engine did not stop" "${upd[@]}" rollback --yes
[ "$(version_of "$app")" = 0.2.0 ] || fail "rollback replaced app after failed stop"
kill -KILL "$daemon"; wait "$daemon" 2>/dev/null || true; daemon=''
echo 0 >"$work/running"
start_daemon
echo "$daemon" >"$NOODLE_HOME/old-pid"
touch "$NOODLE_HOME/fail-start"
rollback_code=0
rollback_out=$("${upd[@]}" rollback --yes 2>&1) || rollback_code=$?
[ "$rollback_code" = 3 ] || fail "rollback restart failure must identify a completed swap: $rollback_out"
[ "$(version_of "$app")" = 0.1.0 ] || fail "restart failure lost the rollback"
grep -q "engine did not restart" <<<"$rollback_out" && ok "rollback preserves a failed engine restart" || fail "rollback restart error lost"
wait "$daemon" 2>/dev/null || true; daemon=''
rm "$NOODLE_HOME/fail-start"
calls=$(wc -l <"$NOODLE_HOME/helper-calls")
"${upd[@]}" stage "${common[@]}" --current-build 1 >/dev/null
"${upd[@]}" install --app "$app" --yes >/dev/null
"${upd[@]}" rollback --yes >/dev/null
[ "$(wc -l <"$NOODLE_HOME/helper-calls")" = "$calls" ] && ok "rollback leaves a stopped engine stopped" || fail "rollback started a stopped engine"
echo 2 >"$work/running"
start_daemon
expect_fail "invalid rollback leaves the engine running" "no update is staged" "${upd[@]}" rollback --yes
kill -0 "$daemon" 2>/dev/null || fail "invalid rollback stopped the engine"
kill "$daemon"; wait "$daemon" 2>/dev/null || true; daemon=''

# 8. managed tools: only Noodle's own out-of-date copies are refreshed; nothing else is touched
[[ $("$noodle" update confirm --app "$work/missing.app" </dev/null) != *refreshing* ]] && ok "no managed tools means nothing to refresh" || fail "refresh without tools"
# Run real refresh through a current bundled helper, rather than trusting a retained CLI's pins.
mkdir -p "$app/Contents/Helpers"
cp "$noodle" "$app/Contents/Helpers/noodle"
mkdir -p "$NOODLE_HOME/tools"
printf '#!/bin/sh\necho old\n' >"$NOODLE_HOME/tools/docker"; chmod +x "$NOODLE_HOME/tools/docker"
touch "$NOODLE_HOME/tools/.docker-1.0.0"
expect_fail "missing installed helper never falls back to old pins" "installed app's Noodle CLI was not found" \
  "$noodle" update confirm --app "$work/missing.app"
expect_fail "stale managed docker is refreshed through the checked download" "download failed for docker" \
  env NOODLE_TOOLS_MIRROR="$base/no-such-mirror" "$noodle" update confirm --app "$app"
grep -q old "$NOODLE_HOME/tools/docker" && ok "a failed refresh keeps the working copy" || fail "docker replaced by a failed download"
[ ! -e "$NOODLE_HOME/tools/cli-plugins" ] || [ -z "$(ls -A "$NOODLE_HOME/tools/cli-plugins")" ] && ok "tools that were never downloaded are not fetched" || fail "plugins fetched"

echo "update.sh: $pass checks passed"
