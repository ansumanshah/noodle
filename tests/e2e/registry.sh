#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: registry credentials and pull paths. Sourced by tests/e2e.sh; do not run directly.

t_registry_credential_helper() {
  authreg 2
  local bin=$WORK/helperbin store=$WORK/helperstore; mkdir -p "$bin" "$store"
  cat >"$bin/docker-credential-e2efake" <<HELPER
#!/bin/sh
echo "\$1" >>"$store/calls"
case \$1 in
  store) cat >"$store/cred" ;;
  get) read -r server; python3 -c '
import json,sys
c=json.load(open("$store/cred"))
print(json.dumps({"ServerURL":c["ServerURL"],"Username":c["Username"],"Secret":c["Secret"]}))' ;;
  erase) rm -f "$store/cred"; cat >/dev/null ;;
esac
HELPER
  chmod +x "$bin/docker-credential-e2efake"
  local oldcfg=$DOCKER_CONFIG cfg=$WORK/helpercfg; mkdir -p "$cfg"
  [ -d "$ROOT/build/tools/cli-plugins" ] && ln -sfn "$ROOT/build/tools/cli-plugins" "$cfg/cli-plugins"
  printf '{"credsStore":"e2efake"}\n' >"$cfg/config.json"
  export DOCKER_CONFIG=$cfg PATH="$bin:$PATH"
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  has "$(cat "$store/calls")" store
  lacks "$(cat "$cfg/config.json")" "$RPASS"
  d tag "$IMG" "$REG/e2e/helper:1"
  d push -q "$REG/e2e/helper:1" >/dev/null
  d rmi "$REG/e2e/helper:1" >/dev/null
  d pull -q "$REG/e2e/helper:1" >/dev/null
  has "$(cat "$store/calls")" get
  d logout "$REG" >/dev/null
  has "$(cat "$store/calls")" erase
  export DOCKER_CONFIG=$oldcfg
}

t_registry_daemon_side_credential() {
  # A client that sends no X-Registry-Auth (a raw API call) is served from the daemon's own Docker config.
  authreg 3
  # A layer the daemon does not have yet: tagging $IMG would pull nothing and print "up to date", as real Docker does.
  d run --name e2e-dside-src "$IMG" sh -c 'echo dside-$$ >/unique' >/dev/null
  d commit e2e-dside-src "$REG/e2e/dside:1" >/dev/null; d rm e2e-dside-src >/dev/null
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d push -q "$REG/e2e/dside:1" >/dev/null
  d rmi "$REG/e2e/dside:1" >/dev/null
  curl -sf --unix-socket "$SOCK" -X POST "http://localhost/images/create?fromImage=$REG/e2e/dside&tag=1" >$WORK/dside.out
  has "$(cat "$WORK/dside.out")" "Pull complete"
  lacks "$(cat "$WORK/dside.out")" "unauthorized"
  d image inspect "$REG/e2e/dside:1" >/dev/null
  d logout "$REG" >/dev/null
}

t_registry_login_private_push_pull() {
  authreg 1
  d login -u "$RUSER" -p wrong "$REG" >/dev/null 2>&1 && { echo "bad password logged in"; return 1; }
  d tag "$IMG" "$REG/e2e/priv:1"
  fails d push -q "$REG/e2e/priv:1"
  has "$(d login -u "$RUSER" -p "$RPASS" "$REG" 2>&1)" "Login Succeeded"
  d push -q "$REG/e2e/priv:1" >/dev/null
  d rmi "$REG/e2e/priv:1" >/dev/null
  d pull -q "$REG/e2e/priv:1" >/dev/null
  d image inspect "$REG/e2e/priv:1" >/dev/null
  d logout "$REG" >/dev/null
  d rmi "$REG/e2e/priv:1" >/dev/null
  fails d pull -q "$REG/e2e/priv:1"
  lacks "$(cat "$DOCKER_CONFIG/config.json" 2>/dev/null)" "$REG"
}

t_registry_pull_cancel_retry() {
  authreg 5
  local c; c=$(mkctx)
  head -c 120000000 /dev/urandom >"$c/blob"
  printf 'FROM scratch\nCOPY blob /blob\n' >"$c/Dockerfile"
  d build -q -t "$REG/e2e/big:1" "$c" >/dev/null
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d push -q "$REG/e2e/big:1" >/dev/null
  local want; want=$(shasum -a 256 <"$c/blob" | cut -d' ' -f1)
  d rmi "$REG/e2e/big:1" >/dev/null
  local i
  for i in 1 2 3; do
    timeout -k 2 "0.$((i * 4))" "$DOCKER" pull -q "$REG/e2e/big:1" >/dev/null 2>&1 || true
  done
  exit_is 0 timeout 10 "$DOCKER" version
  d pull -q "$REG/e2e/big:1" >/dev/null
  d create --name e2e-bigc "$REG/e2e/big:1" x >/dev/null
  d cp e2e-bigc:/blob "$c/back"
  eq "$(shasum -a 256 <"$c/back" | cut -d' ' -f1)" "$want"
  d logout "$REG" >/dev/null
}

t_registry_stalled_address() {
  # A listener that accepts and never answers must not wedge the daemon; a cancelled pull leaves it responsive.
  local p; p=$(port 4)
  python3 - "$p" "$WORK/stall.pid" <<'PYTHON' &
import socket, sys, os, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
open(sys.argv[2], "w").write(str(os.getpid()))
held = []
while True:
    c, _ = s.accept(); held.append(c)
PYTHON
  local srv=$!
  # shellcheck disable=SC2064  # srv is a local that is gone when the EXIT trap runs
  trap "kill $srv 2>/dev/null || true" EXIT
  wait_for 10 test -s "$WORK/stall.pid"
  local t0=$SECONDS
  timeout 4 "$DOCKER" pull -q "127.0.0.1:$p/e2e/none:1" >/dev/null 2>&1 || true
  kill "$srv" 2>/dev/null || true
  [ $((SECONDS - t0)) -lt 12 ] || { echo "client cancel took too long"; return 1; }
  exit_is 0 timeout 10 "$DOCKER" version
  exit_is 0 timeout 20 "$DOCKER" pull -q "$IMG"
}

# The warm pull path answers from the local store after one HEAD. It must never hand back an image the registry no longer serves.
t_pull_warm_path_follows_a_moved_tag() {
  local p; p=$(port 11)
  d run -d --name e2e-wreg -p "$p:5000" registry:2 >/dev/null
  wait_for 30 curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$p/v2/"
  local ref=127.0.0.1:$p/e2e/warm
  warm_mk() { d run --name e2e-wsrc "$IMG" sh -c "echo $2 >/which" >/dev/null; d commit e2e-wsrc "$1" >/dev/null; d rm e2e-wsrc >/dev/null; }
  warm_mk "$ref:1" one
  local idA; idA=$(d image inspect -f '{{.Id}}' "$ref:1")
  d push -q "$ref:1" >/dev/null; d rmi "$ref:1" >/dev/null
  d pull -q "$ref:1" >/dev/null                                   # warm: A is local with its repo digest
  eq "$(d run --rm "$ref:1" cat /which)" one
  warm_mk "$ref:1" two                                            # B takes the local tag
  local idB; idB=$(d image inspect -f '{{.Id}}' "$ref:1")
  d push -q "$ref:1" >/dev/null                                   # the registry now serves B
  d tag "$idA" "$ref:1"                                           # locally the tag is back on A
  eq "$(d image inspect -f '{{.Id}}' "$ref:1")" "$idA"
  d pull -q "$ref:1" >/dev/null
  eq "$(d image inspect -f '{{.Id}}' "$ref:1")" "$idB"           # a stale answer would leave A here
  eq "$(d run --rm "$ref:1" cat /which)" two
}

t_pull_warm_path_restores_a_removed_blob() {
  local p; p=$(port 12)
  d run -d --name e2e-wreg2 -p "$p:5000" registry:2 >/dev/null
  wait_for 30 curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$p/v2/"
  local ref=127.0.0.1:$p/e2e/blob
  d run --name e2e-wsrc2 "$IMG" sh -c 'head -c 200000 /dev/urandom >/payload' >/dev/null
  d commit e2e-wsrc2 "$ref:1" >/dev/null; d rm e2e-wsrc2 >/dev/null
  d push -q "$ref:1" >/dev/null; d rmi "$ref:1" >/dev/null; d pull -q "$ref:1" >/dev/null
  local sum; sum=$(d run --rm "$ref:1" sha256sum /payload)
  local layer config
  layer=$(curl -s -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://127.0.0.1:$p/v2/e2e/blob/manifests/1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["layers"][-1]["digest"].split(":")[1])')
  config=$(d image inspect -f '{{.Id}}' "$ref:1"); config=${config#sha256:}
  local blobs=$NOODLE_HOME/blobs/sha256
  [ -f "$blobs/$layer" ] || { echo "layer blob $layer is not in the store"; return 1; }
  rm -f "$blobs/$layer"
  d pull -q "$ref:1" >/dev/null
  [ -f "$blobs/$layer" ] || { echo "a pull after the layer blob was removed did not fetch it again"; return 1; }
  rm -f "$blobs/$config"
  d pull -q "$ref:1" >/dev/null
  [ -f "$blobs/$config" ] || { echo "a pull after the config blob was removed did not restore it"; return 1; }
  d rmi "$ref:1" >/dev/null; d pull -q "$ref:1" >/dev/null
  eq "$(d run --rm "$ref:1" sha256sum /payload)" "$sum"
}

t_pull_warm_path_keeps_platforms_apart() {
  local arch
  d pull -q --platform linux/amd64 "$IMG" >/dev/null
  arch=$(d image inspect -f '{{.Architecture}}' "$IMG")
  d pull -q --platform linux/arm64 "$IMG" >/dev/null               # give the shared tag back first, whatever happens next
  eq "$arch" amd64
  eq "$(d image inspect -f '{{.Architecture}}' "$IMG")" arm64
  d pull -q --platform linux/amd64 "$IMG" >/dev/null               # both are local now; each pull must pick its own
  arch=$(d image inspect -f '{{.Architecture}}' "$IMG")
  d pull -q --platform linux/arm64 "$IMG" >/dev/null
  eq "$arch" amd64
  eq "$(d image inspect -f '{{.Architecture}}' "$IMG")" arm64
  eq "$(d run --rm --platform linux/arm64 "$IMG" uname -m)" aarch64
}
