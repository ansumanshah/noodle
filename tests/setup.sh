#!/usr/bin/env bash
# Isolated behavioral tests for setup, doctor, and uninstall.
# Usage: NOODLE_BIN=.build/release/noodle DOCKER_BIN=/path/to/docker tests/setup.sh
set -euo pipefail
source_noodle=${NOODLE_BIN:?set NOODLE_BIN}
docker=${DOCKER_BIN:-$(command -v docker || true)}
if [ -z "$docker" ]; then for p in build/tools/docker .build/build/tools/docker .build/tools/docker; do [ ! -x "$p" ] || { docker=$p; break; }; done; fi
[ -n "$docker" ] && [ -x "$docker" ] || { echo 'set DOCKER_BIN to a Docker CLI' >&2; exit 2; }
source_noodle=$(cd "$(dirname "$source_noodle")" && pwd)/$(basename "$source_noodle")
docker=$(cd "$(dirname "$docker")" && pwd)/$(basename "$docker")
timeout_bin=$(command -v gtimeout || command -v timeout || true)
[ -n "$timeout_bin" ] || { echo 'GNU timeout or gtimeout required' >&2; exit 2; }
work=$(mktemp -d /tmp/noodle-setup.XXXXXX); server_pid=''
cleanup() { if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$work"; }
trap cleanup EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
fake_plugin() {  # $1 = path, $2 = version line
  printf '#!/bin/sh\nif [ "$1" = docker-cli-plugin-metadata ]; then echo '"'"'{"SchemaVersion":"0.1.0","Vendor":"test","Version":"v2.40.0","ShortDescription":"fixture"}'"'"'; else echo "%s"; fi\n' "$2" >"$1"
  chmod +x "$1"
}
new_case() {
  case_root="$work/$1"
  mkdir -p "$case_root/home" "$case_root/noodle" "$case_root/docker/cli-plugins" "$case_root/bin"
  export HOME="$case_root/home" NOODLE_HOME="$case_root/noodle" DOCKER_CONFIG="$case_root/docker" PATH="$case_root/bin:/usr/bin:/bin" SHELL=/bin/zsh NOODLE_NO_LAUNCHCTL=1
  unset DOCKER_HOST DOCKER_CONTEXT
  ln -s "$docker" "$case_root/bin/docker"; ln -s /usr/bin/true "$case_root/bin/noodled"; ln -s /usr/bin/true "$case_root/bin/kubectl" # setup skips the kubectl download
  cat >"$case_root/bin/fake-launchctl" <<'SH'
#!/bin/sh
state="$NOODLE_HOME/launchctl.state"
cmd=$1 target=$2
case "$cmd" in
print)
  if [ -f "$state" ] && [ "$(cut -f1 "$state")" = "$target" ]; then
    printf 'program = %s\n' "$(cut -f2- "$state")"
    exit 0
  fi
  exit 1 ;;
bootout)
  if [ -f "$state" ] && [ "$(cut -f1 "$state")" = "$target" ]; then rm -f "$state"; exit 0; fi
  exit 1 ;;
bootstrap) printf '%s\t%s\n' "$target" "${3:-}" >"$state"; exit 0 ;;
*) exit 1 ;;
esac
SH
  chmod +x "$case_root/bin/fake-launchctl"; export NOODLE_LAUNCHCTL="$case_root/bin/fake-launchctl"
  # Plugins answer the docker CLI's metadata handshake, as real ones do: setup checks they work under docker.
  fake_plugin "$case_root/bin/docker-compose" "Docker Compose version v2.40.0"
  fake_plugin "$case_root/bin/docker-buildx" "github.com/docker/buildx v0.30.0"
  chmod +x "$case_root/bin/docker-compose" "$case_root/bin/docker-buildx"
  active_noodle=$source_noodle
}
n() { "$timeout_bin" 15 "$active_noodle" "$@"; }
d() { "$timeout_bin" 15 "$docker" "$@"; }
copy_app() { mkdir -p "$case_root/app/Contents/MacOS"; cp "$source_noodle" "$case_root/app/Contents/MacOS/noodle"; cp /usr/bin/true "$case_root/app/Contents/MacOS/noodled"; active_noodle="$case_root/app/Contents/MacOS/noodle"; }

t_setup_basic() {
  new_case basic; copy_app
  d context create foreign --docker "host=unix://$case_root/foreign.sock" >/dev/null; d context use foreign >/dev/null
  foreign=$(d context inspect foreign)
  n setup --no-start >"$case_root/setup.out"
  [ "$(grep -c 'Docker context currently selected' "$case_root/setup.out")" -eq 1 ] || fail 'context line not printed once'
  ! grep -q '^tools in ' "$case_root/setup.out" || fail 'stray tools line'
  grep -Fq 'docker --context noodle run --rm alpine echo hello' "$case_root/setup.out" || fail 'next step missing'
  grep -Fq 'Docker context stays on foreign. Run noodle setup --use to switch.' "$case_root/setup.out" || fail 'keep line missing'
  [ "$(d context show)" = foreign ] || fail 'setup changed current context'
  d context inspect noodle | grep -q '"Description": "Noodle"' || fail 'Noodle context description missing'
  [ "$(d context inspect foreign)" = "$foreign" ] || fail 'setup altered foreign context'
  stable="$HOME/.local/bin/noodle"
  [ -x "$stable" ] || fail 'stable CLI not installed'
  [ "$(readlink "$HOME/.local/bin/docker")" = "$case_root/bin/docker" ] || fail 'Docker symlink missing'
  [ -L "$DOCKER_CONFIG/cli-plugins/docker-compose" ] && [ -L "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] || fail 'plugins not linked'
  rm -rf "$case_root/app"; active_noodle=$stable; n --version >/dev/null
  n setup --no-start --use >/dev/null; [ "$(d context show)" = noodle ] || fail '--use did not select noodle'
  d context use foreign >/dev/null
  touch "$NOODLE_HOME/data"; mkdir -p "$NOODLE_HOME/run"
  python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()' "$NOODLE_HOME/run/docker.sock"
  n uninstall >/dev/null
  [ -e "$NOODLE_HOME/data" ] || fail 'default uninstall removed data'
  [ ! -e "$HOME/.local/bin/noodle" ] && [ ! -e "$HOME/.local/bin/docker" ] || fail 'owned CLI files remain'
  [ ! -e "$HOME/Library/LaunchAgents/dev.getnoodle.noodled.plist" ] || fail 'LaunchAgent remains'
  [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-compose" ] && [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] || fail 'plugin links remain'
  [ ! -e "$NOODLE_HOME/run/docker.sock" ] || fail 'socket remains'
  d context inspect noodle >/dev/null 2>&1 && fail 'noodle context remains'
  [ "$(d context inspect foreign)" = "$foreign" ] && [ "$(d context show)" = foreign ] || fail 'foreign context changed'
  ok 'setup, --use, stable CLI, uninstall after app deletion, foreign context preservation'
}

t_setup_autouse() {
  new_case autouse; copy_app
  export NOODLE_DEFAULT_DOCKER_SOCKET="$case_root/none.sock"
  n setup --no-start >"$case_root/setup.out"
  [ "$(d context show)" = noodle ] || fail 'setup did not select noodle with no other engine'
  grep -Fq 'then try: docker run --rm alpine echo hello' "$case_root/setup.out" || fail 'plain hello missing'
  n uninstall >/dev/null
  [ "$(d context show)" = default ] || fail 'uninstall did not restore default'
  # A live default socket keeps the context.
  python3 - "$case_root/live.sock" <<'PY' &
import socket,sys,os
s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(4);s.settimeout(20)
try:
    while True:
        c,_=s.accept();c.recv(256);c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK");c.close()
except Exception: pass
PY
  server_pid=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$case_root/live.sock" ] && break; sleep 0.2; done
  export NOODLE_DEFAULT_DOCKER_SOCKET="$case_root/live.sock"
  n setup --no-start >"$case_root/live.out"
  [ "$(d context show)" = default ] || fail 'setup switched away from a running engine'
  grep -Fq 'Docker context stays on default. Run noodle setup --use to switch.' "$case_root/live.out" || fail 'keep line missing for live engine'
  kill "$server_pid" 2>/dev/null || true; server_pid=''
  unset NOODLE_DEFAULT_DOCKER_SOCKET
  ok 'setup selects noodle only when no other engine answers'
}

t_setup_path() {
  new_case path; copy_app; echo 'export KEEP_ME=1' >"$HOME/.zprofile"
  n setup --no-start --path >/dev/null
  grep -q 'KEEP_ME=1' "$HOME/.zprofile" || fail 'existing profile content lost'
  grep -q '# >>> Noodle PATH >>>' "$HOME/.zprofile" || fail 'PATH start marker missing'
  grep -q '# <<< Noodle PATH <<<' "$HOME/.zprofile" || fail 'PATH end marker missing'
  n setup --no-start --path >/dev/null; [ "$(grep -c '# >>> Noodle PATH >>>' "$HOME/.zprofile")" -eq 1 ] || fail 'PATH block duplicated'
  n uninstall >/dev/null; grep -q KEEP_ME "$HOME/.zprofile" || fail 'unrelated profile content lost'
  ! grep -q 'Noodle PATH' "$HOME/.zprofile" || fail 'PATH markers not removed'
  ok 'PATH block add, idempotency, and selective removal'
}

t_setup_bash_login_path() {
  for profile in .profile .bash_login .bash_profile none; do
    new_case "bash-$profile"; copy_app; export SHELL=/bin/bash
    if [ "$profile" != none ]; then printf 'export KEEP_ME=1\n' >"$HOME/$profile"; fi
    n setup --no-start --path >/dev/null
    selected=$profile; [ "$selected" != none ] || selected=.bash_profile
    grep -q 'Noodle PATH' "$HOME/$selected" || fail "PATH not added to $selected"
    if [ "$profile" = .profile ] || [ "$profile" = .bash_login ]; then
      [ ! -e "$HOME/.bash_profile" ] || fail 'setup suppressed existing Bash login file'
    fi
    n setup --no-start --path >/dev/null
    [ "$(grep -c '# >>> Noodle PATH >>>' "$HOME/$selected")" -eq 1 ] || fail 'Bash PATH block duplicated'
    n uninstall >/dev/null
    if [ "$profile" = none ]; then
      [ ! -e "$HOME/.bash_profile" ] || fail 'empty created Bash profile left behind'
    else
      [ "$(cat "$HOME/$selected")" = 'export KEEP_ME=1' ] || fail 'existing Bash content changed'
    fi
  done
  ok 'Bash PATH respects login precedence and removes only its created empty file'
}

t_setup_delete_data() {
  new_case delete-data; touch "$NOODLE_HOME/data"
  if n uninstall --delete-data </dev/null >"$case_root/refusal" 2>&1; then fail 'delete-data without --yes succeeded'; fi
  [ -e "$NOODLE_HOME/data" ] || fail 'unconfirmed deletion removed data'
  n uninstall >/dev/null; [ -e "$NOODLE_HOME/data" ] || fail 'default uninstall removed data'
  if n uninstall --delete-data --yes >/dev/null 2>&1; then fail 'unrecorded data folder was deleted'; fi
  [ -e "$NOODLE_HOME/data" ] || fail 'refused deletion removed data'
  printf 'dev.getnoodle.data.v1\n' >"$NOODLE_HOME/.noodle-data" # what noodle setup records
  n uninstall --delete-data --yes >/dev/null; [ ! -e "$NOODLE_HOME" ] || fail '--yes deletion retained data'
  ok 'delete-data requires --yes and a recorded data folder; default uninstall keeps data'
}

t_setup_doctor() {
  new_case doctor; copy_app
  mkdir -p "$NOODLE_HOME/tools/cli-plugins"
  fake_plugin "$NOODLE_HOME/tools/cli-plugins/docker-buildx" "github.com/docker/buildx v0.39.0"
  printf '%s\n' '{"currentContext":"default","foreign":{"keep":1}}' >"$DOCKER_CONFIG/config.json"
  n setup --no-start >/dev/null; rm -rf "$case_root/app"; active_noodle="$HOME/.local/bin/noodle"
  uid=$(id -u); printf 'gui/%s/dev.getnoodle.noodled\t%s\n' "$uid" "$case_root/app/Contents/MacOS/noodled" >"$NOODLE_HOME/launchctl.state"
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>dev.noodleapps.noodled</string></dict></plist>' >"$HOME/Library/LaunchAgents/dev.noodleapps.noodled.plist"
  d context update noodle --description Noodle --docker "host=unix://$case_root/missing.sock" >/dev/null
  python3 - "$NOODLE_HOME/setup.json" "$DOCKER_CONFIG" "$case_root/missing.sock" <<'PY'
import json,sys
p,c,sock=sys.argv[1:]; d=json.load(open(p)); d['context:'+c]='unix://'+sock; json.dump(d,open(p,'w'))
PY
  rm "$case_root/bin/docker-buildx"
  printf '#!/bin/sh\nexit 0\n' >"$case_root/foreign-plugin"; chmod +x "$case_root/foreign-plugin"
  ln -s "$case_root/foreign-plugin" "$DOCKER_CONFIG/cli-plugins/foreign-plugin"
  mkdir -p "$NOODLE_HOME/run"
  python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()' "$NOODLE_HOME/run/docker.sock"
  status=0; n doctor >"$case_root/dead" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail 'doctor should report unresolved dead socket'
  grep -Fq 'dead Noodle engine socket' "$case_root/dead" || fail 'dead socket diagnosis missing'
  rm "$NOODLE_HOME/run/docker.sock"
  python3 - "$NOODLE_HOME/run/docker.sock" <<'PY' &
import socket,sys
s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(8)
while True:
 c,_=s.accept()
 try:
  req=c.recv(4096)
  if req:
   b=b'{"Version":"99.0.0"}';c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(b)).encode()+b'\r\nConnection: close\r\n\r\n'+b)
 except OSError:pass
 c.close()
PY
  server_pid=$!
  for _ in {1..100}; do [ -S "$NOODLE_HOME/run/docker.sock" ] && break; sleep 0.02; done
  [ -S "$NOODLE_HOME/run/docker.sock" ] || fail 'fake daemon did not bind socket'
  before=$(shasum -a 256 "$DOCKER_CONFIG/config.json")
  status=0; n doctor >"$case_root/report" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail 'doctor report status wrong'
  for label in 'LaunchAgent points to a moved or missing Noodle engine' 'legacy LaunchAgent' 'Noodle Docker context has a stale socket endpoint' 'dangling Noodle plugin link docker-buildx' 'engine version 99.0.0 differs from CLI'; do grep -Fq "$label" "$case_root/report" || fail "doctor misses $label"; done
  [ "$before" = "$(shasum -a 256 "$DOCKER_CONFIG/config.json")" ] || fail 'doctor changed Docker config bytes'
  grep -q 'Run `noodle doctor --fix` to repair' "$case_root/report" || fail 'doctor report did not name the repair command'
  status=0; n doctor --fix >"$case_root/fix" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail 'doctor --fix should leave version mismatch unresolved'
  for label in 'fixed: LaunchAgent points to a moved or missing Noodle engine' 'fixed: legacy LaunchAgent dev.noodleapps.noodled' 'fixed: Noodle Docker context has a stale socket endpoint' 'fixed: dangling Noodle plugin link docker-buildx'; do grep -Fq "$label" "$case_root/fix" || fail "doctor --fix misses $label"; done
  [ ! -e "$HOME/Library/LaunchAgents/dev.noodleapps.noodled.plist" ] && [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] || fail 'doctor --fix left owned issue'
  [ -L "$DOCKER_CONFIG/cli-plugins/foreign-plugin" ] || fail 'doctor --fix removed foreign plugin'
  d context inspect noodle | grep -q "$NOODLE_HOME/run/docker.sock" || fail 'context endpoint not repaired'
  [ ! -e "$NOODLE_HOME/launchctl.state" ] || fail 'loaded stale agent not booted out'
  grep -q '99.0.0 differs from CLI' "$case_root/fix" || fail 'version mismatch not reported after fix'
  kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; server_pid=''
  ok 'doctor reports issues and repairs only Noodle-owned artifacts'
}

t_setup_dead_socket_fixed() {
  new_case dead; copy_app; n setup --no-start >/dev/null
  python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()' "$NOODLE_HOME/run/docker.sock"
  n doctor --fix >"$case_root/fix"
  grep -q 'fixed: dead Noodle engine socket' "$case_root/fix" || fail 'dead socket not fixed'
  [ ! -e "$NOODLE_HOME/run/docker.sock" ] || fail 'dead socket remains'
  ok 'doctor --fix removes a refused socket'
}

t_setup_foreign_owned_names() {
  new_case foreign; copy_app
  d context create noodle --description Foreign --docker "host=unix://$case_root/foreign.sock" >/dev/null
  d context use noodle >/dev/null
  printf '#!/bin/sh\nexit 0\n' >"$case_root/foreign-plugin"; chmod +x "$case_root/foreign-plugin"
  ln -s "$case_root/foreign-plugin" "$DOCKER_CONFIG/cli-plugins/docker-buildx"
  context_before=$(d context inspect noodle)
  config_before=$(shasum -a 256 "$DOCKER_CONFIG/config.json")
  if n setup --no-start >"$case_root/setup" 2>&1; then fail 'setup overwrote foreign noodle context'; fi
  if n doctor --fix >"$case_root/doctor" 2>&1; then fail 'doctor silently accepted foreign context'; fi
  n uninstall >/dev/null
  [ "$(d context inspect noodle)" = "$context_before" ] || fail 'foreign noodle context changed'
  [ "$(shasum -a 256 "$DOCKER_CONFIG/config.json")" = "$config_before" ] || fail 'foreign context selection/config changed'
  [ "$(readlink "$DOCKER_CONFIG/cli-plugins/docker-buildx")" = "$case_root/foreign-plugin" ] || fail 'foreign plugin link changed'
  ok 'foreign context named noodle and user plugin links are preserved'
}

t_setup_doctor_names_fixes() {
  new_case fixes; copy_app
  n setup --no-start >/dev/null
  n doctor >"$case_root/healthy" || fail 'doctor reported an issue on a fresh setup'
  python3 - "$DOCKER_CONFIG/config.json" <<'PY'
import json, sys
path = sys.argv[1]; config = json.load(open(path))
config.update(credsStore="gone", credHelpers={"ghcr.io": "present", "quay.io": "absent"})
json.dump(config, open(path, "w"))
PY
  printf '#!/bin/sh\nexit 0\n' >"$case_root/bin/docker-credential-present"; chmod +x "$case_root/bin/docker-credential-present"
  ln -s "$case_root/missing-plugin" "$DOCKER_CONFIG/cli-plugins/foreign-plugin"
  before=$(shasum -a 256 "$DOCKER_CONFIG/config.json")
  status=0; n doctor --fix >"$case_root/report" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail 'doctor --fix should leave missing credential helpers unresolved'
  for helper in gone absent; do grep -Fq "issue: Docker credential helper docker-credential-$helper is not on PATH" "$case_root/report" || fail "doctor misses helper $helper"; done
  ! grep -q 'docker-credential-present' "$case_root/report" || fail 'doctor flagged a helper that is on PATH'
  [ "$(grep -c '^issue: ' "$case_root/report")" = "$(grep -c '^  fix: ' "$case_root/report")" ] || fail 'an unrepaired issue has no fix line'
  grep -Fq "fix: reinstall the tool that owns it, or remove $DOCKER_CONFIG/cli-plugins/foreign-plugin" "$case_root/report" || fail 'foreign plugin link has no fix line'
  [ "$before" = "$(shasum -a 256 "$DOCKER_CONFIG/config.json")" ] || fail 'doctor changed Docker config bytes'
  ok 'doctor names a fix for every issue it cannot repair, including missing credential helpers'
}

t_setup_legacy_loaded() {
  new_case legacy; copy_app
  printf 'gui/%s/dev.noodleapps.noodled\t%s\n' "$(id -u)" "$case_root/old/noodled" >"$NOODLE_HOME/launchctl.state"
  n doctor --fix >"$case_root/fix"
  grep -q 'fixed: legacy LaunchAgent dev.noodleapps.noodled' "$case_root/fix" || fail 'loaded legacy label not repaired'
  [ ! -e "$NOODLE_HOME/launchctl.state" ] || fail 'loaded legacy agent not booted out'
  ok 'loaded legacy agent without a plist is removed'
}

t_setup_missing_tools() {
  # The app's setup sheet must not treat a quiet exit as success: a missing docker fails, missing plugins are named.
  for p in /opt/homebrew/bin /usr/local/bin /usr/local/cli-plugins /Applications/Docker.app/Contents/Resources/cli-plugins; do
    [ ! -e "$p/docker" ] && [ ! -e "$p/docker-compose" ] && [ ! -e "$p/docker-buildx" ] || { echo "skip setup_missing_tools: $p holds a real Docker tool, so discovery would find it"; return 0; }
  done
  new_case missing; copy_app
  rm "$case_root/bin/docker" "$case_root/bin/docker-compose" "$case_root/bin/docker-buildx"
  mkdir -p "$case_root/mirror"
  status=0; NOODLE_TOOLS_MIRROR="file://$case_root/mirror" n setup --no-start --no-use >"$case_root/none" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'setup exited 0 with no docker CLI'
  grep -Fq 'download failed for docker' "$case_root/none" || fail 'missing docker download failure not named'
  d context inspect noodle >/dev/null 2>&1 && fail 'context created without a docker CLI'
  ln -s "$docker" "$case_root/bin/docker"
  n setup --no-start --no-use >"$case_root/plugins" 2>&1 || fail 'setup failed when only plugins are missing'
  for name in compose buildx; do
    grep -q "Noodle lazy Docker plugin: docker-$name" "$DOCKER_CONFIG/cli-plugins/docker-$name" || fail 'missing plugin stub'
  done
  n setup --no-start --no-use >"$case_root/retry" 2>&1 || fail 'setup retry failed with stubs'
  ! grep -q 'warning: existing.*cli-plugins' "$case_root/retry" || fail 'setup warned about a lazy plugin'
  n uninstall >/dev/null
  [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-compose" ] && [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] || fail 'uninstall retained stubs'
  ok 'setup fetches Docker automatically, defers missing plugins, and uninstalls stubs'
}

t_tools_install_checks() {
  # The assistant downloads with `tools install <names>` and applies setup afterwards, so the download alone must
  # change nothing: a bad name is refused, a failed checksum installs nothing, and a killed download's folder is cleared.
  new_case toolsinstall
  status=0; n tools install nosuch >"$case_root/out" 2>&1 || status=$?
  [ "$status" -eq 2 ] && grep -Fq 'usage: noodle tools install' "$case_root/out" || fail 'an unknown tool name should print usage and exit 2'
  mkdir -p "$case_root/mirror" "$NOODLE_HOME/tools/.download-99999999"
  echo bogus >"$case_root/mirror/docker-compose-darwin-aarch64"
  status=0; NOODLE_TOOLS_MIRROR="file://$case_root/mirror" n tools install --no-link docker-compose >"$case_root/out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a file with the wrong checksum was accepted'
  grep -Fq 'SHA-256 mismatch' "$case_root/out" && grep -Fq 'Nothing from this download was installed.' "$case_root/out" || fail 'checksum failure not reported plainly'
  [ ! -e "$NOODLE_HOME/tools/cli-plugins/docker-compose" ] || fail 'a file that failed its checksum was installed'
  [ ! -e "$NOODLE_HOME/tools/.download-99999999" ] || fail 'a dead download folder was kept'
  [ ! -e "$NOODLE_HOME/dev.noodleapps.noodled.plist" ] && [ ! -e "$HOME/Library/LaunchAgents/dev.getnoodle.noodled.plist" ] || fail 'tools install wrote a launch agent'
  d context inspect noodle >/dev/null 2>&1 && fail 'tools install created a Docker context'
  ok 'tools install downloads only: bad names refused, a failed checksum installs nothing'
}

t_tools_checksum_preserves_earlier_setup() {
  new_case checksum-retains; copy_app
  n setup --no-start --no-use --path >"$case_root/setup.out"
  mkdir -p "$NOODLE_HOME/tools" "$case_root/mirror"
  echo 'previous tool' >"$NOODLE_HOME/tools/docker"
  echo bogus >"$case_root/mirror/docker-compose-darwin-aarch64"
  local config_before profile_before cli_before tool_before
  # --no-use may leave no config file, so its absence is compared too.
  config_before=$(cat "$DOCKER_CONFIG/config.json" 2>/dev/null || echo absent)
  profile_before=$(shasum -a 256 "$HOME/.zprofile")
  cli_before=$(shasum -a 256 "$HOME/.local/bin/noodle")
  tool_before=$(shasum -a 256 "$NOODLE_HOME/tools/docker")
  status=0; NOODLE_TOOLS_MIRROR="file://$case_root/mirror" n tools install --no-link docker-compose >"$case_root/out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'checksum failure exited successfully'
  grep -Fq 'Earlier setup changes remain.' "$case_root/out" || fail 'retained changes were not disclosed'
  [ "$config_before" = "$(cat "$DOCKER_CONFIG/config.json" 2>/dev/null || echo absent)" ] || fail 'failed download changed Docker configuration'
  [ "$profile_before" = "$(shasum -a 256 "$HOME/.zprofile")" ] || fail 'failed download changed the shell profile'
  [ "$cli_before" = "$(shasum -a 256 "$HOME/.local/bin/noodle")" ] || fail 'failed download changed the retained CLI'
  [ "$tool_before" = "$(shasum -a 256 "$NOODLE_HOME/tools/docker")" ] || fail 'failed download changed an earlier tool'
  [ -e "$HOME/Library/LaunchAgents/dev.getnoodle.noodled.plist" ] || fail 'failed download removed the launch agent'
  [ ! -e "$NOODLE_HOME/tools/cli-plugins/docker-compose" ] || fail 'bad download was installed'
  ok 'checksum failure keeps and discloses earlier setup changes'
}

t_setup_basic
t_tools_install_checks
t_tools_checksum_preserves_earlier_setup
t_setup_missing_tools
t_setup_autouse
t_setup_path
t_setup_bash_login_path
t_setup_delete_data
t_setup_doctor
t_setup_dead_socket_fixed
t_setup_foreign_owned_names
t_setup_doctor_names_fixes
t_setup_legacy_loaded
echo "setup.sh: $pass checks passed"
