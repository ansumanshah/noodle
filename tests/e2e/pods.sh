#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: pods. Sourced by tests/e2e.sh; do not run directly.

# ======================================================================= checks: pods
# Keep the pod cases together. Each catches a CLI orchestration failure through
# the real engine; pod_cli resolves the binary in the same way as scan_cli.
pod_cli() { PATH="$(dirname "$DOCKER"):$PATH" timeout -k 5 "$TIMEOUT" "${NOODLE_BIN:-$ROOT/.build/release/noodle}" pod "$@"; }
# Express membership through standard Docker flags, matching the documented path.
pod_member() {
  local pod=$1 network
  shift
  pod_cli start "$pod" >/dev/null
  network=$(d ps -aq --no-trunc --filter "label=dev.noodle.pod=$pod" --filter label=dev.noodle.pod.role=infra)
  nonempty "$network" 'pod network container'
  d run --network "container:$network" --label "dev.noodle.pod=$pod" \
    --label dev.noodle.pod.role=member --label "dev.noodle.pod.infra=$network" "$@"
}
pod_server() {
  pod_member "$1" -d --name "$2" "$IMG" sh -c '
    printf "%s\n" "#!/bin/sh" '\''printf "HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\npod-localhost\n"'\'' > /tmp/reply
    chmod +x /tmp/reply
    echo pod-ready
    exec nc -lk -p 8080 -e /tmp/reply' >/dev/null
}
pod_localhost() { d exec "$1" wget -q -T 2 -O - http://127.0.0.1:8080; }
t_pod_create_inspect_and_validation() {
  pod_cli create --name e2e-pod-meta --label team=containers --share net --json >"$WORK/pod-create.json"
  pod_cli inspect e2e-pod-meta --json >"$WORK/pod-inspect.json"
  python3 - "$WORK/pod-create.json" "$WORK/pod-inspect.json" <<'PYPOD'
import json, sys
created, pod = [json.load(open(p)) for p in sys.argv[1:]]
assert created['id'] == pod['id']
assert pod['name'] == 'e2e-pod-meta'
assert pod['share'] == ['net']
assert pod['infra']['Config']['Labels']['dev.noodle.pod'] == 'e2e-pod-meta'
assert pod['infra']['Config']['Labels']['team'] == 'containers'
assert pod['infra']['Config']['Image'] == 'alpine:3.22'
assert pod['members'] == []
assert not pod['infra']['State']['Running']
PYPOD
  has "$(pod_cli ps)" e2e-pod-meta
  has "$(pod_cli inspect e2e-pod-meta)" e2e-pod-meta
  pod_cli ps --json >"$WORK/pod-ps.json"
  python3 - "$WORK/pod-ps.json" <<'PYPOD'
import json, sys
assert any(p['name'] == 'e2e-pod-meta' for p in json.load(open(sys.argv[1])))
PYPOD
  fails pod_cli create --name e2e-pod-meta
  fails pod_cli create --name e2e-pod-invalid --label dev.noodle.pod=other
  fails pod_cli create --name e2e-pod-invalid --share net,ipc
  fails pod_cli create --name e2e-pod-invalid --share uts
  fails pod_cli create --name e2e-pod-invalid --share pid
  fails pod_cli create --name e2e-pod-invalid --share ''
  eq "$(d ps -aq --filter name=e2e-pod-invalid)" ''
  pod_cli rm e2e-pod-meta >/dev/null
}
t_pod_localhost_and_shared_publish() {
  local hp infra
  hp=$(port 75)
  pod_cli create --name e2e-pod-net --publish "127.0.0.1:$hp:8080" >/dev/null
  pod_server e2e-pod-net e2e-pod-server
  pod_member e2e-pod-net --detach=1 --name e2e-pod-client --label team=pods --no-healthcheck "$IMG" sleep 600 >"$WORK/pod-run.id"
  eq "$(wc -c <"$WORK/pod-run.id" | tr -d ' ')" 65
  eq "$(insp e2e-pod-client '{{index .Config.Labels "team"}}')" pods
  has "$(pod_cli inspect e2e-pod-net)" e2e-pod-client
  wait_for 20 pod_localhost e2e-pod-client
  eq "$(pod_localhost e2e-pod-client)" pod-localhost
  wait_for 20 http_get "http://127.0.0.1:$hp"
  eq "$(http_get "http://127.0.0.1:$hp")" pod-localhost
  infra=$(d ps -aq --no-trunc --filter label=dev.noodle.pod=e2e-pod-net --filter label=dev.noodle.pod.role=infra)
  nonempty "$infra" infra
  eq "$(insp e2e-pod-client '{{.HostConfig.NetworkMode}}')" "container:$infra"
  has "$(d port "$infra")" "$hp"
  eq "$(d port e2e-pod-server)" ''
  # Command arguments and option values that resemble Docker flags are preserved.
  eq "$(pod_member e2e-pod-net --rm -e 'POD_VALUE=--net=host' "$IMG" sh -c 'echo "$POD_VALUE"')" --net=host
  fails pod_cli run e2e-pod-net -d "$IMG" sleep 600
  pod_cli rm -f e2e-pod-net >/dev/null
}
t_pod_restart_shared_network() {
  local before after infra hp
  hp=$(port 76)
  pod_cli create --name e2e-pod-restart -p "127.0.0.1:$hp:8080" >/dev/null
  pod_server e2e-pod-restart e2e-pod-restart-server
  pod_member e2e-pod-restart -d --name e2e-pod-restart-client "$IMG" sleep 600 >/dev/null
  infra=$(d ps -aq --filter label=dev.noodle.pod=e2e-pod-restart --filter label=dev.noodle.pod.role=infra)
  wait_for 20 pod_localhost e2e-pod-restart-client
  before=$(d exec "$infra" readlink /proc/self/ns/net)
  pod_cli restart e2e-pod-restart --json >"$WORK/pod-restart.json"
  after=$(d exec "$infra" readlink /proc/self/ns/net)
  [ "$before" != "$after" ] || { echo 'infra network namespace did not change'; return 1; }
  eq "$(d exec e2e-pod-restart-server readlink /proc/self/ns/net)" "$after"
  eq "$(d exec e2e-pod-restart-client readlink /proc/self/ns/net)" "$after"
  wait_for 20 pod_localhost e2e-pod-restart-client
  eq "$(pod_localhost e2e-pod-restart-client)" pod-localhost
  wait_for 20 http_get "http://127.0.0.1:$hp"
  eq "$(http_get "http://127.0.0.1:$hp")" pod-localhost
  # start also recovers members left in the old namespace after an external
  # infra stop. Skipping already-running members here would strand localhost.
  d stop -t 1 "$infra" >/dev/null
  pod_cli start e2e-pod-restart >/dev/null
  after=$(d exec "$infra" readlink /proc/self/ns/net)
  eq "$(d exec e2e-pod-restart-client readlink /proc/self/ns/net)" "$after"
  wait_for 20 pod_localhost e2e-pod-restart-client
  pod_cli stop e2e-pod-restart >/dev/null
  pod_cli start e2e-pod-restart >/dev/null
  wait_for 20 pod_localhost e2e-pod-restart-client
  pod_cli rm -f e2e-pod-restart >/dev/null
}
t_pod_restart_refuses_autoremove() {
  local infra before
  pod_cli create --name e2e-pod-auto >/dev/null
  pod_member e2e-pod-auto -d --rm --name e2e-pod-auto-member "$IMG" sleep 600 >/dev/null
  infra=$(d ps -aq --filter label=dev.noodle.pod=e2e-pod-auto --filter label=dev.noodle.pod.role=infra)
  before=$(insp "$infra" '{{.State.StartedAt}}')
  fails pod_cli restart e2e-pod-auto
  is_running "$infra"
  is_running e2e-pod-auto-member
  eq "$(insp "$infra" '{{.State.StartedAt}}')" "$before"
  d stop -t 1 "$infra" >/dev/null
  fails pod_cli start e2e-pod-auto
  is_running e2e-pod-auto-member
  fails is_running "$infra"
  pod_cli rm -f e2e-pod-auto >/dev/null
  eq "$(d ps -aq --filter label=dev.noodle.pod=e2e-pod-auto)" ''
}
t_pod_stop_and_rm() {
  pod_cli create --name e2e-pod-life >/dev/null
  pod_member e2e-pod-life -d --name e2e-pod-life-member "$IMG" sleep 600 >/dev/null
  # A refused non-force remove must leave every container intact.
  fails pod_cli rm e2e-pod-life
  is_running e2e-pod-life-member
  eq "$(d ps -aq --filter label=dev.noodle.pod=e2e-pod-life | wc -l | tr -d ' ')" 2
  pod_cli stop e2e-pod-life --json >"$WORK/pod-stop.json"
  eq "$(d ps -q --filter label=dev.noodle.pod=e2e-pod-life)" ''
  pod_cli stop e2e-pod-life >/dev/null
  pod_cli rm e2e-pod-life --json >"$WORK/pod-rm.json"
  eq "$(d ps -aq --filter label=dev.noodle.pod=e2e-pod-life)" ''
  fails pod_cli inspect e2e-pod-life
  pod_cli create --name e2e-pod-force >/dev/null
  pod_member e2e-pod-force -d --name e2e-pod-force-member "$IMG" sleep 600 >/dev/null
  pod_cli rm -f e2e-pod-force >/dev/null
  eq "$(d ps -aq --filter label=dev.noodle.pod=e2e-pod-force)" ''
}
t_pod_logs_and_top() {
  pod_cli create --name e2e-pod-observe >/dev/null
  pod_server e2e-pod-observe e2e-pod-observe-server
  wait_for 20 pod_localhost e2e-pod-observe-server
  pod_cli logs e2e-pod-observe --json >"$WORK/pod-logs.json"
  pod_cli top e2e-pod-observe --json >"$WORK/pod-top.json"
  python3 - "$WORK/pod-logs.json" "$WORK/pod-top.json" <<'PYPOD'
import json, sys
logs, top = [json.load(open(p)) for p in sys.argv[1:]]
assert any(r['container'] == 'e2e-pod-observe-server' and 'pod-ready' in r['logs'] for r in logs)
assert any(r['container'] == 'e2e-pod-observe-server' and r['processes'] for r in top)
assert all(r['titles'] for r in top)
PYPOD
  has "$(pod_cli logs e2e-pod-observe)" pod-ready
  has "$(pod_cli top e2e-pod-observe)" e2e-pod-observe-server
  pod_cli rm -f e2e-pod-observe >/dev/null
}
# =================================================================== end pod checks

# Scan helpers run on the host. This is the supplied alpine:3.10.1 arm64 v8
# manifest. Grype 0.121.3 reports CVE-2019-14697 for it (verified by scan-known-cve-and-fail-on).
E2E_SCAN_IMAGE=${E2E_SCAN_IMAGE:-docker.io/library/alpine@sha256:b206388a8e17c4a9c8e1c0d8f28dde06632dee48ac8409a6e5460280f978f593}
scan_cli() { timeout -k 5 "${E2E_SCAN_TIMEOUT:-1200}" "${NOODLE_SCAN_CLI:-$ROOT/.build/release/noodle}" "$@"; }
scan_fixture() {
  has "$E2E_SCAN_IMAGE" '@sha256:'
  timeout 120 "$DOCKER" pull -q "$E2E_SCAN_IMAGE" >/dev/null
}
t_scan_unused_and_missing_image() {
  local h="$WORK/scan-unused" msg
  mkdir -p "$h"
  NOODLE_HOME="$h" scan_cli version
  NOODLE_HOME="$h" scan_cli scan --history >"$WORK/scan-empty.json"
  eq "$(cat "$WORK/scan-empty.json")" '[]'
  [ ! -e "$h/tools/scanners" ]
  [ ! -e "$h/cache/scans" ]
  msg=$(scan_cli scan noodle-scan-missing:absent 2>&1) && return 1
  has "$msg" 'No such image'
  msg=$(scan_cli sbom noodle-scan-missing:absent 2>&1) && return 1
  has "$msg" 'No such image'
  NOODLE_HOME="$h" exit_is 2 scan_cli scan --clear-cache unexpected
}
t_scan_known_cve_and_fail_on() {
  scan_fixture
  scan_cli scan "$E2E_SCAN_IMAGE" --json >"$WORK/scan.json"
  python3 - "$WORK/scan.json" <<'PYCVE'
import json, sys
r = json.load(open(sys.argv[1]))
assert any(m['vulnerability']['id'] == 'CVE-2019-14697' for m in r['matches'])
PYCVE
  exit_is 2 scan_cli scan "$E2E_SCAN_IMAGE" --fail-on negligible --json
  exit_is 0 scan_cli scan "$E2E_SCAN_IMAGE" --json
  exit_is 2 scan_cli scan "$E2E_SCAN_IMAGE" --fail-on invalid
}
t_scan_sbom_cyclonedx() {
  scan_fixture
  scan_cli sbom "$E2E_SCAN_IMAGE" --output "$WORK/sbom.json"
  python3 - "$WORK/sbom.json" <<'PYSBOM'
import json, sys
r = json.load(open(sys.argv[1]))
assert r['bomFormat'] == 'CycloneDX'
assert any(c['name'] == 'musl' for c in r['components'])
PYSBOM
}
t_scan_history_offline_and_clear_cache() {
  scan_fixture
  scan_cli scan "$E2E_SCAN_IMAGE" --json >/dev/null
  local h="$WORK/scan-offline"
  mkdir -p "$h/scans"
  cp -R "$NOODLE_HOME/scans/history" "$h/scans/"
  NOODLE_HOME="$h" scan_cli scan --history "$E2E_SCAN_IMAGE" >"$WORK/history.json"
  python3 - "$WORK/history.json" <<'PYHISTORY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r and r[-1]['result']['matches']
PYHISTORY
  [ ! -e "$h/tools" ]
  [ ! -e "$h/cache" ]
  mkdir -p "$h/cache/scans/grype/db"
  touch "$h/cache/scans/grype/db/old"
  NOODLE_HOME="$h" scan_cli scan --clear-cache
  [ ! -e "$h/cache/scans" ]
  NOODLE_HOME="$h" scan_cli scan --history "$E2E_SCAN_IMAGE" >"$WORK/history-after.json"
  cmp "$WORK/history.json" "$WORK/history-after.json"
}
t_scan_tampered_helper_refused() {
  scan_fixture
  # Seed the real verified helper first, then alter only a private copy.
  scan_cli scan "$E2E_SCAN_IMAGE" --json >/dev/null
  local h binary msg
  h="$NOODLE_HOME/sc-$$-$RANDOM"; mkdir -p "$h"   # short and removed with the home: socket paths cap at 104 bytes
  mkdir -p "$h/tools"
  cp -R "$NOODLE_HOME/tools/scanners" "$h/tools/"
  binary=$(find "$h/tools/scanners" -type f -name grype | head -1)
  [ -n "$binary" ]
  [ -f "$(dirname "$binary")/verified.json" ]
  printf '\nchanged\n' >>"$binary"
  # Resolve the image through the real daemon without copying the full store.
  ln -s "$NOODLE_HOME/run" "$h/run"
  ln -s "$NOODLE_HOME/images.json" "$h/images.json"
  ln -s "$NOODLE_HOME/blobs" "$h/blobs"
  msg=$(NOODLE_HOME="$h" scan_cli scan "$E2E_SCAN_IMAGE" --json 2>&1) && return 1
  has "$msg" 'Could not verify installed grype'
}

t_scan_tampered_archive_refused() {
  scan_fixture
  local h payload="$WORK/scan-archive-payload" msg
  h="$NOODLE_HOME/sc-$$-$RANDOM"; mkdir -p "$h"   # short and removed with the home: socket paths cap at 104 bytes
  mkdir -p "$payload"
  # A valid tar containing an executable must fail its archive hash before extraction.
  printf '#!/bin/sh\ntouch "%s"\n' "$h/executed" >"$payload/grype"
  chmod +x "$payload/grype"
  /usr/bin/tar -czf "$WORK/tampered-grype.tar.gz" -C "$payload" grype
  ln -s "$NOODLE_HOME/run" "$h/run"
  ln -s "$NOODLE_HOME/images.json" "$h/images.json"
  ln -s "$NOODLE_HOME/blobs" "$h/blobs"
  msg=$(NOODLE_HOME="$h" NOODLE_SCAN_TOOL_ARCHIVE="$WORK/tampered-grype.tar.gz" scan_cli scan "$E2E_SCAN_IMAGE" --json 2>&1) && return 1
  has "$msg" 'SHA-256 mismatch for grype_0.121.3_darwin_arm64.tar.gz'
  [ ! -e "$h/tools/scanners/grype-0.121.3" ]
  [ ! -e "$h/executed" ]
  [ ! -e "$h/cache/scans" ]
}


# Container edits exercise the public CLI and Docker's immediate view of its state.
edit_cli() { timeout -k 5 60 "${NOODLE_CLI:-$ROOT/.build/release/noodle}" container "$@"; }
edit_d() { timeout -k 5 60 "$DOCKER" "$@"; }
# alpine's busybox has no httpd applet, so serve through nc like the other fixtures. The body is
# $EDIT_RESTART when set, so an environment change is visible over HTTP after a restart.
EDIT_SERVER='cat >/tmp/reply <<"X"
#!/bin/sh
b=${EDIT_RESTART:-edit-ok}
printf "HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s\n" $((${#b}+1)) "$b"
X
chmod +x /tmp/reply
exec nc -lk -p 80 -e /tmp/reply'
edit_serve() {
  edit_d run -d --name "$1" "$IMG" sh -c "$EDIT_SERVER" >/dev/null
}
t_edit_running_port_preserves_pid_and_releases_binding() {
  local p pid
  p=$(port 110)
  edit_serve e2e-edit-live
  pid=$(edit_d inspect -f '{{.State.Pid}}' e2e-edit-live)
  edit_cli edit e2e-edit-live --publish "127.0.0.1:$p:80"
  wait_for 20 http_get "http://127.0.0.1:$p"
  eq "$(http_get "http://127.0.0.1:$p")" edit-ok
  eq "$(edit_d inspect -f '{{.State.Pid}}' e2e-edit-live)" "$pid"
  eq "$(edit_d port e2e-edit-live 80/tcp)" "127.0.0.1:$p"
  has "$(edit_d ps --filter name=e2e-edit-live --format '{{.Ports}}')" "$p->80/tcp"
  edit_cli edit e2e-edit-live --unpublish "127.0.0.1:$p:80"
  eq "$(edit_d port e2e-edit-live)" ''
  fails http_get "http://127.0.0.1:$p"
  edit_d run -d --name e2e-edit-reuse -p "127.0.0.1:$p:80" "$IMG" sleep 600 >/dev/null
  eq "$(edit_d port e2e-edit-reuse 80/tcp)" "127.0.0.1:$p"
}
t_edit_conflict_leaves_all_state_unchanged() {
  local p before pid
  p=$(port 111)
  edit_d run -d --name e2e-edit-holder -p "127.0.0.1:$p:80" "$IMG" sleep 600 >/dev/null
  edit_serve e2e-edit-conflict
  before=$(edit_d inspect -f '{{json .Config.Env}} {{json .HostConfig.PortBindings}} {{json .NetworkSettings.Ports}}' e2e-edit-conflict)
  pid=$(edit_d inspect -f '{{.State.Pid}}' e2e-edit-conflict)
  fails edit_cli edit e2e-edit-conflict --env EDIT_CONFLICT=changed --publish "127.0.0.1:$(port 112):80" --publish "127.0.0.1:$p:81" --restart
  eq "$(edit_d inspect -f '{{json .Config.Env}} {{json .HostConfig.PortBindings}} {{json .NetworkSettings.Ports}}' e2e-edit-conflict)" "$before"
  eq "$(edit_d inspect -f '{{.State.Pid}}' e2e-edit-conflict)" "$pid"
  fails edit_cli edit e2e-edit-conflict --env BROKEN
  fails edit_cli edit e2e-edit-conflict --env =empty
  fails edit_cli edit e2e-edit-conflict --publish bogus
  fails edit_cli edit e2e-edit-conflict --publish "127.0.0.1:70000:80"
  eq "$(edit_d inspect -f '{{json .Config.Env}} {{json .HostConfig.PortBindings}} {{json .NetworkSettings.Ports}}' e2e-edit-conflict)" "$before"
  # The successfully staged first listener must have been rolled back too.
  edit_d run -d --name e2e-edit-rollback -p "127.0.0.1:$(port 112):80" "$IMG" sleep 600 >/dev/null
}
t_edit_ipv6_and_loopback_specs() {
  local p
  p=$(port 113)
  edit_serve e2e-edit-v6
  edit_cli edit e2e-edit-v6 --publish "[::1]:$p:80"
  wait_for 20 curl -g -sf --noproxy '*' --max-time 3 "http://[::1]:$p"
  eq "$(curl -g -sf --noproxy '*' --max-time 3 "http://[::1]:$p")" edit-ok
  eq "$(edit_d port e2e-edit-v6 80/tcp)" "[::1]:$p"
  edit_cli edit e2e-edit-v6 --unpublish "[::1]:$p:80" --publish "127.0.0.1:$p:80"
  eq "$(edit_d port e2e-edit-v6 80/tcp)" "127.0.0.1:$p"
  eq "$(http_get "http://127.0.0.1:$p")" edit-ok
}
t_edit_env_applies_on_restart_and_keeps_writable_layer() {
  local id pid
  edit_d run -d --name e2e-edit-env -e EDIT_VALUE=before -e EDIT_REMOVE=yes "$IMG" sleep 600 >/dev/null
  id=$(edit_d inspect -f '{{.Id}}' e2e-edit-env)
  pid=$(edit_d inspect -f '{{.State.Pid}}' e2e-edit-env)
  edit_d exec e2e-edit-env sh -c 'echo kept >/tmp/edit-data'
  has "$(edit_cli edit e2e-edit-env --env EDIT_VALUE=after --unset-env EDIT_REMOVE)" 'next start'
  has "$(edit_d inspect -f '{{json .Config.Env}}' e2e-edit-env)" EDIT_VALUE=after
  lacks "$(edit_d inspect -f '{{json .Config.Env}}' e2e-edit-env)" EDIT_REMOVE=
  eq "$(edit_d inspect -f '{{.State.Pid}}' e2e-edit-env)" "$pid"
  has "$(edit_d exec e2e-edit-env sh -c "tr '\\0' '\\n' </proc/1/environ")" EDIT_VALUE=before
  edit_cli edit e2e-edit-env --restart
  eq "$(edit_d inspect -f '{{.Id}}' e2e-edit-env)" "$id"
  has "$(edit_d exec e2e-edit-env sh -c "tr '\\0' '\\n' </proc/1/environ")" EDIT_VALUE=after
  lacks "$(edit_d exec e2e-edit-env sh -c "tr '\\0' '\\n' </proc/1/environ")" EDIT_REMOVE=
  eq "$(edit_d exec e2e-edit-env cat /tmp/edit-data)" kept
}
t_edit_restart_keeps_live_ports_network_and_volume() {
  local p id ip mounts
  p=$(port 118)
  edit_d volume create e2e-edit-restart-data >/dev/null
  edit_d run -d --name e2e-edit-restart -e EDIT_RESTART=before -v e2e-edit-restart-data:/data "$IMG" sh -c "$EDIT_SERVER" >/dev/null
  edit_d exec e2e-edit-restart sh -c 'echo writable >/tmp/edit-marker; echo volume >/data/edit-marker'
  edit_cli edit e2e-edit-restart --publish "127.0.0.1:$p:80"
  wait_for 20 http_get "http://127.0.0.1:$p"
  eq "$(http_get "http://127.0.0.1:$p")" before
  id=$(edit_d inspect -f '{{.Id}}' e2e-edit-restart)
  # Membership is kept. The address is leased again at start, as in `docker restart`, so compare networks, not IPs.
  ip=$(edit_d inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.NetworkID}} {{end}}' e2e-edit-restart)
  mounts=$(edit_d inspect -f '{{json .Mounts}}' e2e-edit-restart)
  edit_cli edit e2e-edit-restart --env EDIT_RESTART=after --restart
  wait_for 20 http_get "http://127.0.0.1:$p"
  eq "$(http_get "http://127.0.0.1:$p")" after
  eq "$(edit_d inspect -f '{{.Id}}' e2e-edit-restart)" "$id"
  eq "$(edit_d inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.NetworkID}} {{end}}' e2e-edit-restart)" "$ip"
  eq "$(edit_d inspect -f '{{json .Mounts}}' e2e-edit-restart)" "$mounts"
  eq "$(edit_d inspect -f '{{.Name}}' e2e-edit-restart)" /e2e-edit-restart
  eq "$(edit_d port e2e-edit-restart 80/tcp)" "127.0.0.1:$p"
  eq "$(edit_d exec e2e-edit-restart cat /tmp/edit-marker)" writable
  eq "$(edit_d exec e2e-edit-restart cat /data/edit-marker)" volume
  fails edit_d run -d --name e2e-edit-restart-conflict -p "127.0.0.1:$p:80" "$IMG" sleep 600
}
t_edit_dry_run_changes_nothing() {
  local before pid
  edit_serve e2e-edit-dry
  before=$(edit_d inspect -f '{{json .Config.Env}} {{json .HostConfig.PortBindings}} {{json .NetworkSettings.Ports}}' e2e-edit-dry)
  pid=$(edit_d inspect -f '{{.State.Pid}}' e2e-edit-dry)
  edit_cli edit e2e-edit-dry --env EDIT_DRY=yes --publish "127.0.0.1:$(port 114):80" --restart --dry-run
  eq "$(edit_d inspect -f '{{json .Config.Env}} {{json .HostConfig.PortBindings}} {{json .NetworkSettings.Ports}}' e2e-edit-dry)" "$before"
  eq "$(edit_d inspect -f '{{.State.Pid}}' e2e-edit-dry)" "$pid"
  edit_d run -d --name e2e-edit-dry-reuse -p "127.0.0.1:$(port 114):80" "$IMG" sleep 600 >/dev/null
}
t_edit_ports_discovers_unpublished_tcp_udp_and_rejects_stopped() {
  local ports
  edit_serve e2e-edit-discover
  edit_d exec -d e2e-edit-discover nc -u -l -p 5354
  wait_for 20 edit_d exec e2e-edit-discover sh -c 'grep -q :14EA /proc/net/udp /proc/net/udp6'
  ports=$(edit_cli ports e2e-edit-discover --json)
  printf '%s' "$ports" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert any(x["port"]==80 and x["protocol"]=="tcp" and not x["published"] and x.get("process")=="nc" for x in p),p; assert any(x["port"]==5354 and x["protocol"]=="udp" for x in p),p'
  edit_cli edit e2e-edit-discover --publish "127.0.0.1:$(port 115):80"
  edit_cli ports e2e-edit-discover --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert any(x["port"]==80 and x["published"] for x in p),p'
  edit_d stop -t 1 e2e-edit-discover >/dev/null
  fails edit_cli ports e2e-edit-discover --json
  edit_d rm e2e-edit-discover >/dev/null
  fails edit_cli edit e2e-edit-discover --env REMOVED=yes
  fails edit_cli edit e2e-edit-missing --publish 'bogus'
}
t_edit_compose_container_stays_in_project() {
  local c id
  c=$(mkctx)
  printf 'services:\n  web:\n    image: %s\n    command: [sleep, "600"]\n' "$IMG" >"$c/compose.yaml"
  edit_d compose -p e2e-edit-compose -f "$c/compose.yaml" up -d
  id=$(edit_d compose -p e2e-edit-compose -f "$c/compose.yaml" ps -q web)
  nonempty "$id"
  edit_cli edit "$id" --env EDIT_COMPOSE=yes --publish "127.0.0.1:$(port 116):80"
  eq "$(edit_d compose -p e2e-edit-compose -f "$c/compose.yaml" ps -q web)" "$id"
  has "$(edit_d compose -p e2e-edit-compose -f "$c/compose.yaml" ps --format json)" "${id:0:12}"
  edit_d compose -p e2e-edit-compose -f "$c/compose.yaml" down
}
t_edit_state_survives_daemon_restart() {
  # A private daemon avoids disrupting the suite's daemon or an external engine.
  local edit_home edit_pid edit_sock p
  edit_home=$(mktemp -d /tmp/noodle-edit.XXXXXX)
  edit_pid=''
  trap '[ -z "$edit_pid" ] || { kill -TERM "$edit_pid" 2>/dev/null; wait "$edit_pid" 2>/dev/null; }; rm -rf "$edit_home"' EXIT
  mkdir -p "$edit_home/boot"
  cp "$RES/vmlinux" "$RES/initramfs.cpio.gz" "$edit_home/boot/"
  export NOODLE_HOME=$edit_home
  edit_sock=$edit_home/run/docker.sock
  export DOCKER_HOST=unix://$edit_sock
  "$NOODLED" >"$edit_home/daemon.log" 2>&1 & edit_pid=$!
  wait_for 30 curl -sf --max-time 2 --unix-socket "$edit_sock" http://localhost/_ping
  edit_d pull -q "$IMG" >/dev/null
  edit_d run -d --name e2e-edit-persist "$IMG" sleep 600 >/dev/null
  p=$(port 117)
  edit_cli edit e2e-edit-persist --env EDIT_PERSIST=yes --publish "127.0.0.1:$p:80"
  edit_d stop -t 1 e2e-edit-persist >/dev/null
  kill -TERM "$edit_pid"; wait "$edit_pid"; edit_pid=''
  rm -f "$edit_home/vm.log"
  "$NOODLED" >>"$edit_home/daemon.log" 2>&1 & edit_pid=$!
  wait_for 30 curl -sf --max-time 2 --unix-socket "$edit_sock" http://localhost/_ping
  fails edit_cli ports e2e-edit-persist --json
  edit_cli edit e2e-edit-persist --env EDIT_STOPPED_DRY=yes --publish "127.0.0.1:$(port 119):81" --dry-run
  lacks "$(edit_d inspect -f '{{json .Config.Env}}' e2e-edit-persist)" EDIT_STOPPED_DRY=
  lacks "$(edit_d inspect -f '{{json .HostConfig.PortBindings}}' e2e-edit-persist)" "$(port 119)"
  [ ! -e "$edit_home/vm.log" ] || { echo "stopped-container dry run booted the VM"; return 1; }
  edit_cli edit e2e-edit-persist --env EDIT_STOPPED=yes
  [ ! -e "$edit_home/vm.log" ] || { echo "stopped-container request booted the VM"; return 1; }
  has "$(edit_d inspect -f '{{json .Config.Env}}' e2e-edit-persist)" EDIT_PERSIST=yes
  has "$(edit_d inspect -f '{{json .HostConfig.PortBindings}}' e2e-edit-persist)" "$p"
  edit_d start e2e-edit-persist >/dev/null
  eq "$(edit_d port e2e-edit-persist 80/tcp)" "127.0.0.1:$p"
  eq "$(edit_d exec e2e-edit-persist printenv EDIT_STOPPED)" yes
  kill -TERM "$edit_pid"; wait "$edit_pid"; edit_pid=''
  rm -rf "$edit_home"
  trap - EXIT
}

# Pod management keeps its finite Docker deadline. Members are launched by Docker directly.
t_pod_foreground_run_has_no_deadline() {
  local shim=$WORK/pod-deadline-shim response
  mkdir -p "$shim"
  printf '#!/bin/sh\nsleep 5\nexec "%s" "$@"\n' "$DOCKER" >"$shim/docker"
  chmod 755 "$shim/docker"
  if response=$(PATH="$shim:$(dirname "$DOCKER"):$PATH" NOODLE_POD_DEADLINE_SECONDS=2 \
      timeout -k 5 "$TIMEOUT" "${NOODLE_BIN:-$ROOT/.build/release/noodle}" pod create --name e2e-pod-deadline-bounded 2>&1); then
    echo "a pod create past the deadline was accepted: $response"; return 1
  fi
  has "$response" "exceeded its 2 second deadline"
  pod_cli create --name e2e-pod-deadline >/dev/null
  eq "$(NOODLE_POD_DEADLINE_SECONDS=2 pod_member e2e-pod-deadline --rm "$IMG" sh -c 'sleep 3; echo ran-past-deadline')" ran-past-deadline
  pod_cli rm -f e2e-pod-deadline >/dev/null
  pod_cli rm -f e2e-pod-deadline-bounded >/dev/null 2>&1 || true
}

# A Docker client disconnect does not end the exec process inside the container.
# Exercise explicit SIGHUP cleanup through a per-session PID file.
t_terminal_close_hangs_up_container_shell() {
  local token="e2e-term-$$-$RANDOM" c=e2e-term-hup out
  local shell_script='echo $$ > /tmp/.noodle-term-$1 2>/dev/null; if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'
  local cleanup_script='f=/tmp/.noodle-term-$1; [ -f "$f" ] && kill -HUP "$(cat "$f")" 2>/dev/null; rm -f "$f"'
  d run -d --name $c "$IMG" sleep 600 >/dev/null
  out=$(timeout -k 5 120 python3 "$ROOT/tests/terminal_hangup.py" "$DOCKER" $c "$token" "$shell_script" "$cleanup_script")
  eq "$out" ok
  fails d exec $c sh -c 'ls /tmp/.noodle-term-* >/dev/null 2>&1'
  d rm -f $c >/dev/null
}

