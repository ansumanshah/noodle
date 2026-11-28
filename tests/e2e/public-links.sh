#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: public-links. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: public links
# Each check owns its daemon, helper and VM. The fake never contacts Cloudflare.
link_up() { # [bad-digest|real]
  [ -n "${NOODLED:-}" ] && [ -x "$NOODLED" ] || { echo "noodled not built"; return 1; }
  LINK_CLI=${NOODLE_CLI:-}
  if [ -z "$LINK_CLI" ]; then
    local candidate
    for candidate in "$(dirname "$NOODLED")/noodle" "$ROOT/.build/release/noodle" "$ROOT/.build/debug/noodle"; do
      if [ -x "$candidate" ]; then LINK_CLI=$candidate; break; fi
    done
  fi
  [ -x "$LINK_CLI" ] || { echo "noodle CLI not built (set NOODLE_CLI)"; return 1; }
  LINK_HOME=$(mktemp -d /tmp/noodle-link.XXXXXX)
  LINK_SOCK=$LINK_HOME/run/docker.sock; LINK_DAEMON_PID=""; LINK_MODE=${1:-fake}
  trap link_down EXIT
  mkdir -p "$LINK_HOME/boot"
  local f
  for f in vmlinux initramfs.cpio.gz; do
    [ ! -f "$RES/$f" ] || { cp -c "$RES/$f" "$LINK_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$LINK_HOME/boot/$f"; }
  done
  cat >"$LINK_HOME/cloudflared" <<'SH'
#!/bin/sh
# A file named mode beside the pid file picks a misbehaviour: stubborn ignores TERM, apierror prints only an error.
mode=$(cat "$(dirname "$NOODLE_LINK_TEST_PID")/mode" 2>/dev/null)
printf '%s\n' "$@" >"$NOODLE_LINK_TEST_ARGS"
printf '%s\n' "$$" >"$NOODLE_LINK_TEST_PID"
printf '%s\n' "$$" >>"$NOODLE_LINK_TEST_PID.all"
[ "$mode" != stubborn ] || trap '' TERM HUP INT
if [ "$mode" = apierror ]; then
  echo 'ERR Failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": dial tcp: lookup failed' >&2
  exec sleep 600
fi
printf '%s\n' 'INF Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):' \
  'INF |  https://fixture-link.trycloudflare.com  |' >&2
exec sleep 600
SH
  chmod 700 "$LINK_HOME/cloudflared"
  LINK_DIGEST=$(shasum -a 256 "$LINK_HOME/cloudflared" | awk '{print $1}')
  [ "$LINK_MODE" != bad-digest ] || LINK_DIGEST=$(printf '%064d' 0)
  tar -czf "$LINK_HOME/cf.tgz" -C "$LINK_HOME" cloudflared
  LINK_ARCHIVE_DIGEST=$(shasum -a 256 "$LINK_HOME/cf.tgz" | awk '{print $1}')
  [ "$LINK_MODE" != archive-bad ] || LINK_ARCHIVE_DIGEST=$(printf '%064d' 0)
  link_daemon_start
  ld pull -q "$IMG" >/dev/null
}
link_daemon_start() {
  local helper_env=()
  if [ "$LINK_MODE" = real ] || [ "$LINK_MODE" = cached ]; then
    helper_env=(-u NOODLE_CLOUDFLARED -u NOODLE_CLOUDFLARED_SHA256)
  elif [ "$LINK_MODE" = archive-ok ] || [ "$LINK_MODE" = archive-bad ]; then
    helper_env=(-u NOODLE_CLOUDFLARED -u NOODLE_CLOUDFLARED_SHA256 "NOODLE_CLOUDFLARED_ARCHIVE=$LINK_HOME/cf.tgz"
      "NOODLE_CLOUDFLARED_ARCHIVE_SHA256=$LINK_ARCHIVE_DIGEST"
      "NOODLE_LINK_TEST_ARGS=$LINK_HOME/helper.args" "NOODLE_LINK_TEST_PID=$LINK_HOME/helper.pid")
  else
    helper_env=("NOODLE_CLOUDFLARED=$LINK_HOME/cloudflared" "NOODLE_CLOUDFLARED_SHA256=$LINK_DIGEST"
      "NOODLE_LINK_TEST_ARGS=$LINK_HOME/helper.args" "NOODLE_LINK_TEST_PID=$LINK_HOME/helper.pid")
  fi
  # LINK_NOODLED / LINK_START_DIR let a check start the daemon from a fake app bundle, by a relative path.
  ( cd "${LINK_START_DIR:-.}" && exec env "${helper_env[@]}" NOODLE_HOME="$LINK_HOME" NOODLE_MEMORY_MIB=1024 NOODLE_CPUS=2 \
    NOODLE_NAMES_HTTP_PORT=0 NOODLE_NAMES_HTTPS_PORT=0 \
    NOODLE_HTTP_PORT=$((PORT_BASE + 96)) NOODLE_HTTPS_PORT=$((PORT_BASE + 97)) \
    "${LINK_NOODLED:-$NOODLED}" >>"$LINK_HOME/noodled.log" 2>&1 ) &
  LINK_DAEMON_PID=$!
  wait_for 60 curl -sf --max-time 2 --unix-socket "$LINK_SOCK" http://localhost/_ping
}
link_daemon_stop() {
  if [ -n "${LINK_DAEMON_PID:-}" ]; then
    kill -TERM "$LINK_DAEMON_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 40); do kill -0 "$LINK_DAEMON_PID" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$LINK_DAEMON_PID" 2>/dev/null || true
    wait "$LINK_DAEMON_PID" 2>/dev/null || true
    LINK_DAEMON_PID=""
  fi
}
link_down() {
  set +e
  link_daemon_stop
  if [ -f "${LINK_HOME:-}/helper.pid" ]; then kill -TERM "$(cat "$LINK_HOME/helper.pid")" 2>/dev/null; fi
  [ -z "${LINK_HOME:-}" ] || rm -rf "$LINK_HOME"
  return 0
}
ld() { DOCKER_HOST=unix://$LINK_SOCK timeout -k 5 120 "$DOCKER" "$@"; }
lc() { NOODLE_HOME=$LINK_HOME DOCKER_HOST=unix://$LINK_SOCK timeout -k 5 150 "$LINK_CLI" "$@"; }
link_serve() { # name [docker flags]; distinctive response for Host routing checks
  local name=$1; shift
  ld run -d --name "$name" --expose 80 "$@" "$IMG" sh -c '
    # The Alpine busybox has no httpd: answer with the hostname through nc, as serve() does.
    cat >/tmp/reply <<"EOF"
#!/bin/sh
h=$(hostname)
printf "HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" "${#h}" "$h"
EOF
    chmod +x /tmp/reply
    exec nc -lk -p 80 -e /tmp/reply' >/dev/null
}
link_field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
link_create() {
  LINK_JSON=$(lc link "$1" --yes --json)
  LINK_ID=$(printf '%s' "$LINK_JSON" | link_field id)
  LINK_TARGET=$(printf '%s' "$LINK_JSON" | link_field target)
  LINK_HELPER_PID=$(cat "$LINK_HOME/helper.pid")
}
link_state_is() {
  lc link list --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); sys.exit(0 if any(r["id"]==sys.argv[1] and r["state"]==sys.argv[2] and (sys.argv[2] not in ("failed","stopped") or r.get("detail")) for r in rows) else 1)' "$1" "$2"
}
link_helper_gone() { ! kill -0 "$LINK_HELPER_PID" 2>/dev/null; }

t_link_requires_explicit_confirmation() {
  link_up
  link_serve e2e-link-confirm
  fails lc link e2e-link-confirm:80 --json
  [ ! -f "$LINK_HOME/helper.pid" ]
  eq "$(lc link list --json)" '[]'
}
t_link_json_and_helper_arguments_pin_one_service() {
  link_up
  link_serve e2e-link-web --hostname link-web
  link_serve e2e-link-other --hostname link-other
  link_create e2e-link-web
  printf '%s' "$LINK_JSON" | python3 -c '
import json,sys,urllib.parse
r=json.load(sys.stdin); u=urllib.parse.urlsplit(r["target"])
assert all(k in r for k in ("id","containerID","containerName","containerIP","containerPort","target","url","state")), r
assert r["containerName"]=="e2e-link-web" and r["containerPort"]==80, r
assert r["url"]=="https://fixture-link.trycloudflare.com" and r["state"]=="running", r
assert u.scheme=="http" and u.hostname=="127.0.0.1" and u.port>1024, r'
  python3 - "$LINK_HOME/helper.args" "$LINK_TARGET" <<'PY'
import sys
args=open(sys.argv[1]).read().splitlines()
assert args[args.index("--url")+1]==sys.argv[2], args
assert "--no-autoupdate" in args, args
assert args[args.index("--metrics")+1]=="127.0.0.1:0", args
PY
  wait_for 20 link_state_is "$LINK_ID" running
  wait_for 20 link_web_reachable
  eq "$(curl -sf --max-time 5 -H 'Host: e2e-link-other.localhost' "$LINK_TARGET")" link-web
  lc link list --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert len(rows)==1 and rows[0]["id"]==sys.argv[1]' "$LINK_ID"
}
link_web_reachable() { [ "$(curl -sf --max-time 3 "$LINK_TARGET")" = link-web ]; }
t_link_digest_mismatch_refuses_helper() {
  link_up bad-digest
  link_serve e2e-link-digest
  fails lc link e2e-link-digest:80 --yes --json
  [ ! -f "$LINK_HOME/helper.pid" ]
}
t_link_cached_executable_tampering_is_refused() {
  link_up cached
  link_serve e2e-link-cached-tamper
  local binary=$LINK_HOME/tools/cloudflared-2026.11.0 response
  mkdir -p "$LINK_HOME/tools"
  cp "$LINK_HOME/cloudflared" "$binary"
  printf 'sha256:%s' "$LINK_DIGEST" >"$binary.sha256"
  printf '\n# changed after installation\n' >>"$binary"
  if response=$(lc link e2e-link-cached-tamper:80 --yes --json 2>&1); then
    echo "a changed installed executable was accepted"; return 1
  fi
  has "$response" "installed cloudflared SHA-256 mismatch"
  [ ! -f "$LINK_HOME/helper.pid" ]
}
t_link_cached_executable_requires_recorded_hash() {
  link_up cached
  link_serve e2e-link-cached-nohash
  local binary=$LINK_HOME/tools/cloudflared-2026.11.0 response
  mkdir -p "$LINK_HOME/tools"
  cp "$LINK_HOME/cloudflared" "$binary"
  if response=$(lc link e2e-link-cached-nohash:80 --yes --json 2>&1); then
    echo "an installed executable without a recorded hash was accepted"; return 1
  fi
  has "$response" "missing executable hash"
  [ ! -f "$LINK_HOME/helper.pid" ]
}
t_link_stop_reaps_helper_and_closes_relay() {
  link_up
  link_serve e2e-link-stop
  link_create e2e-link-stop:80
  lc link stop "$LINK_ID"
  link_helper_gone
  wait_for 10 link_state_is "$LINK_ID" stopped
  fails curl -sf --max-time 3 "$LINK_TARGET"
  lc link stop --all
}
t_link_stop_all_reaps_every_helper() {
  link_up
  link_serve e2e-link-all-one
  link_serve e2e-link-all-two
  link_create e2e-link-all-one:80
  local first_pid=$LINK_HELPER_PID first_id=$LINK_ID first_target=$LINK_TARGET
  link_create e2e-link-all-two:80
  lc link stop --all
  link_helper_gone
  LINK_HELPER_PID=$first_pid
  link_helper_gone
  wait_for 10 link_state_is "$first_id" stopped
  wait_for 10 link_state_is "$LINK_ID" stopped
  fails curl -sf --max-time 3 "$first_target"
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
t_link_container_stop_reaps_helper() {
  link_up
  link_serve e2e-link-stop-container
  link_create e2e-link-stop-container:80
  ld stop -t 1 e2e-link-stop-container >/dev/null
  wait_for 10 link_helper_gone
  wait_for 10 link_state_is "$LINK_ID" stopped
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
t_link_container_remove_reaps_helper() {
  link_up
  link_serve e2e-link-remove
  link_create e2e-link-remove:80
  ld rm -f e2e-link-remove >/dev/null
  wait_for 10 link_helper_gone
  wait_for 10 link_state_is "$LINK_ID" stopped
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
t_link_helper_crash_is_reported() {
  link_up
  link_serve e2e-link-crash
  link_create e2e-link-crash:80
  kill -KILL "$LINK_HELPER_PID"
  wait_for 10 link_state_is "$LINK_ID" failed
  lc link list --json | python3 -c 'import json,sys; row=next(r for r in json.load(sys.stdin) if r["id"]==sys.argv[1]); assert row["detail"], row' "$LINK_ID"
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
t_link_daemon_restart_does_not_restore_public_access() {
  link_up
  link_serve e2e-link-restart
  link_create e2e-link-restart:80
  link_daemon_stop
  wait_for 10 link_helper_gone
  rm "$LINK_HOME/helper.pid"
  link_daemon_start
  lc link list --json | python3 -c 'import json,sys; assert all(r["state"] not in ("running","starting") for r in json.load(sys.stdin))'
  [ ! -f "$LINK_HOME/helper.pid" ]
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
t_link_daemon_crash_reaps_helper_and_closes_relay() {
  link_up
  link_serve e2e-link-daemon-crash
  link_create e2e-link-daemon-crash:80
  kill -KILL "$LINK_DAEMON_PID"
  wait "$LINK_DAEMON_PID" 2>/dev/null || true
  LINK_DAEMON_PID=""
  wait_for 10 link_helper_gone
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
t_link_invalid_targets_fail_without_starting_helper() {
  link_up
  link_serve e2e-link-invalid
  fails lc link no-such-link-container:80 --yes --json
  fails lc link e2e-link-invalid:0 --yes --json
  fails lc link e2e-link-invalid:65536 --yes --json
  fails lc link e2e-link-invalid:12345 --yes --json
  fails lc link /var/run/docker.sock --yes --json
  ld run -d --name e2e-link-noport "$IMG" sleep 600 >/dev/null
  fails lc link e2e-link-noport --yes --json
  ld stop -t 1 e2e-link-invalid >/dev/null
  fails lc link e2e-link-invalid:80 --yes --json
  [ ! -f "$LINK_HOME/helper.pid" ]
}
t_link_docker_api_port_and_host_network_are_refused() {
  link_up
  ld run -d --name e2e-link-docker-api --expose 2375 "$IMG" sleep 600 >/dev/null
  fails lc link e2e-link-docker-api:2375 --yes --json
  fails lc link e2e-link-docker-api --yes --json
  ld run -d --name e2e-link-host --network host --expose 80 "$IMG" sleep 600 >/dev/null
  fails lc link e2e-link-host:80 --yes --json
  [ ! -f "$LINK_HOME/helper.pid" ]
}
t_link_privileged_container_requires_separate_consent() {
  link_up
  link_serve e2e-link-privileged --privileged
  fails lc link e2e-link-privileged:80 --yes --json
  [ ! -f "$LINK_HOME/helper.pid" ]
  LINK_JSON=$(lc link e2e-link-privileged:80 --yes --allow-privileged --json)
  LINK_ID=$(printf '%s' "$LINK_JSON" | link_field id)
  wait_for 10 link_state_is "$LINK_ID" running
  lc link stop --all
}
link_all_helpers_gone() { local p; for p in $(cat "$LINK_HOME/helper.pid.all" 2>/dev/null); do ! kill -0 "$p" 2>/dev/null || return 1; done; }
link_list_row() { lc link list --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin) if x["id"]==sys.argv[1]][0]; print(r[sys.argv[2]])' "$1" "$2"; }
# After a revocation the link must stay stopped, never come back with the container, and nothing may answer on its relay.
link_stays_revoked() {
  wait_for 20 link_state_is "$LINK_ID" stopped
  wait_for 10 link_helper_gone
  sleep 4
  link_state_is "$LINK_ID" stopped
  eq "$(wc -l <"$LINK_HOME/helper.pid.all" | tr -d ' ')" 1
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
link_refused() { # container[:port] message-fragment [flags]
  local target=$1 want=$2 response; shift 2
  if response=$(lc link "$target" --yes --json "$@" 2>&1); then echo "link to $target was accepted: $response"; return 1; fi
  has "$response" "$want"
}
t_link_pause_revokes_link() {
  link_up; link_serve e2e-link-pause; link_create e2e-link-pause:80
  ld pause e2e-link-pause >/dev/null
  link_stays_revoked
}
t_link_network_disconnect_revokes_link() {
  link_up; ld network create e2e-link-net >/dev/null
  link_serve e2e-link-disc --network e2e-link-net; link_create e2e-link-disc:80
  ld network disconnect e2e-link-net e2e-link-disc >/dev/null
  link_stays_revoked
}
t_link_restart_revokes_link() {
  link_up; link_serve e2e-link-restart-c; link_create e2e-link-restart-c:80
  ld restart -t 1 e2e-link-restart-c >/dev/null
  link_stays_revoked
}
t_link_restart_policy_revokes_link() {
  link_up; link_serve e2e-link-policy --restart always; link_create e2e-link-policy:80
  ld kill e2e-link-policy >/dev/null
  link_stays_revoked
}
t_link_supervisor_killed_alone_reaps_helper() {
  link_up; link_serve e2e-link-sup; link_create e2e-link-sup:80
  kill -KILL "$(link_list_row "$LINK_ID" pid)"
  wait_for 15 link_helper_gone
  wait_for 10 link_state_is "$LINK_ID" failed
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
t_link_supervisor_signals_reap_helper() {
  link_up; link_serve e2e-link-sig; local sig
  for sig in TERM INT HUP; do
    link_create e2e-link-sig:80
    kill -"$sig" "$(link_list_row "$LINK_ID" pid)"
    wait_for 15 link_helper_gone
    wait_for 10 link_state_is "$LINK_ID" failed
  done
}
t_link_helper_ignoring_sigterm_is_killed() {
  link_up; link_serve e2e-link-stubborn; echo stubborn >"$LINK_HOME/mode"
  link_create e2e-link-stubborn:80
  lc link stop "$LINK_ID"
  wait_for 15 link_helper_gone
  fails curl -sf --max-time 3 "$LINK_TARGET"
}
t_link_two_links_daemon_crash_reaps_both() {
  link_up; link_serve e2e-link-two-a; link_serve e2e-link-two-b
  link_create e2e-link-two-a:80; link_create e2e-link-two-b:80
  eq "$(wc -l <"$LINK_HOME/helper.pid.all" | tr -d ' ')" 2
  kill -KILL "$LINK_DAEMON_PID"; wait "$LINK_DAEMON_PID" 2>/dev/null || true; LINK_DAEMON_PID=""
  # No race: Foundation spawns close every fd but 0-2, so each lifetime pipe's writer lives only in noodled and EOF is
  # certain once it dies; EOF is level-triggered, so a supervisor still hashing its helper sees it on its first read.
  # The whole check passes in under 8 s, also under 8x CPU load; the 30 s wait absorbs a starved host running VM shards.
  wait_for 30 link_all_helpers_gone
}
t_link_socket_and_parent_directory_mounts_are_refused() {
  link_up; local flag
  # A bind of the API socket is the Docker-socket feature, so the container starts; a link to it must still be refused.
  for flag in "$LINK_SOCK:/var/run/outer.sock" "$LINK_HOME/run:/outer-run" "$LINK_HOME:/outer-home"; do
    ld rm -f e2e-link-mount >/dev/null 2>&1 || true
    ld run -d --name e2e-link-mount --expose 80 -v "$flag" "$IMG" sleep 600 >/dev/null || { echo "could not start the mount fixture for $flag"; return 1; }
    link_refused e2e-link-mount:80 "socket mounts"
  done
  [ ! -f "$LINK_HOME/helper.pid" ]
}
t_link_network_modes_and_namespace_sharers_are_refused() {
  link_up
  ld run -d --name e2e-link-nonet --network none --expose 80 "$IMG" sleep 600 >/dev/null
  link_refused e2e-link-nonet:80 "bridge address"
  ld run -d --name e2e-link-base --expose 80 "$IMG" sleep 600 >/dev/null
  ld run -d --name e2e-link-sharer --network container:e2e-link-base --expose 80 "$IMG" sleep 600 >/dev/null
  link_refused e2e-link-sharer:80 "bridge address"
  link_refused e2e-link-base:80 "shares this container's network namespace"
  ld rm -f e2e-link-sharer >/dev/null
  link_create e2e-link-base:80
  lc link stop --all
}
t_link_seccomp_unconfined_needs_allow_privileged() {
  link_up
  ld run -d --name e2e-link-unconfined --security-opt seccomp=unconfined --expose 80 "$IMG" sleep 600 >/dev/null
  link_refused e2e-link-unconfined:80 "--allow-privileged"
  [ ! -f "$LINK_HOME/helper.pid" ]
}
t_link_direct_api_without_confirmation_is_refused() {
  link_up; link_serve e2e-link-api
  local body code
  for body in '{"container":"e2e-link-api","port":80}' '{"container":"e2e-link-api","port":80,"confirmed":false}'; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$LINK_SOCK" -X POST -d "$body" http://localhost/noodle/links)
    case $code in 2*) echo "unconfirmed POST was accepted ($code)"; return 1 ;; esac
  done
  [ ! -f "$LINK_HOME/helper.pid" ]
  eq "$(lc link list --json)" '[]'
}
t_link_download_archive_mismatch_is_refused() {
  link_up archive-bad; link_serve e2e-link-arch-bad
  link_refused e2e-link-arch-bad:80 "archive SHA-256 mismatch"
  ! ls "$LINK_HOME"/tools/cloudflared-* >/dev/null 2>&1
  [ ! -f "$LINK_HOME/helper.pid" ]
}
t_link_download_archive_installs_verified_executable() {
  link_up archive-ok; link_serve e2e-link-arch-ok; link_create e2e-link-arch-ok:80
  local binary=$LINK_HOME/tools/cloudflared-2026.11.0
  [ -x "$binary" ]
  eq "$(cat "$binary.sha256")" "sha256:$LINK_DIGEST"
  wait_for 20 link_state_is "$LINK_ID" running
  lc link stop --all
}
t_link_cached_executable_with_recorded_hash_runs() {
  link_up cached; link_serve e2e-link-cached-ok
  local binary=$LINK_HOME/tools/cloudflared-2026.11.0
  mkdir -p "$LINK_HOME/tools"; cp "$LINK_HOME/cloudflared" "$binary"; printf 'sha256:%s' "$LINK_DIGEST" >"$binary.sha256"
  local json; json=$(lc link e2e-link-cached-ok:80 --yes --json)
  eq "$(printf '%s' "$json" | link_field state)" running
  eq "$(printf '%s' "$json" | link_field url)" https://fixture-link.trycloudflare.com
  lc link stop --all
}
t_link_api_endpoint_in_error_output_is_not_a_tunnel() {
  link_up; link_serve e2e-link-apierr; echo apierror >"$LINK_HOME/mode"
  link_refused e2e-link-apierr:80 "did not provide a public URL"
  lc link list --json | python3 -c 'import json,sys; assert all(r["state"]!="running" and not r.get("url") for r in json.load(sys.stdin))'
}
t_link_app_bundle_layout_starts_the_cli_not_the_gui() {
  link_up; link_daemon_stop
  local app=$LINK_HOME/Fake.app/Contents
  mkdir -p "$app/MacOS" "$app/Helpers"
  cp -c "$NOODLED" "$app/MacOS/noodled" 2>/dev/null || cp "$NOODLED" "$app/MacOS/noodled"
  cp -c "$LINK_CLI" "$app/Helpers/noodle" 2>/dev/null || cp "$LINK_CLI" "$app/Helpers/noodle"
  # Stands in for the GUI binary: a case-insensitive lookup of "noodle" in MacOS would run it. It never opens a window.
  printf '#!/bin/sh\ntouch "%s/gui-launched"\nexit 0\n' "$LINK_HOME" >"$app/MacOS/Noodle"; chmod 755 "$app/MacOS/Noodle"
  LINK_NOODLED=./noodled LINK_START_DIR=$app/MacOS link_daemon_start
  link_serve e2e-link-bundle; link_create e2e-link-bundle:80
  [ ! -e "$LINK_HOME/gui-launched" ]
  wait_for 20 link_state_is "$LINK_ID" running
  lc link stop --all
  [ ! -e "$LINK_HOME/gui-launched" ]
}
t_link_real_tunnel_reaches_selected_container() {
  [ "${NOODLE_E2E_REAL_TUNNEL:-0}" = 1 ] || skip "set NOODLE_E2E_REAL_TUNNEL=1 for public-network smoke test"
  link_up real
  link_serve e2e-link-real --hostname link-real
  local json url
  json=$(lc link e2e-link-real:80 --yes --json)
  url=$(printf '%s' "$json" | link_field url)
  case "$url" in https://*.trycloudflare.com) ;; *) echo "unexpected tunnel URL: $url"; return 1 ;; esac
  wait_for 30 link_real_reachable "$url"
  lc link stop --all
  wait_for 30 link_real_dead "$url"
  # Container teardown and daemon teardown must each kill a fresh URL too.
  json=$(lc link e2e-link-real:80 --yes --json); url=$(printf '%s' "$json" | link_field url)
  wait_for 30 link_real_reachable "$url"
  ld stop -t 1 e2e-link-real >/dev/null
  wait_for 30 link_real_dead "$url"
  ld start e2e-link-real >/dev/null
  json=$(lc link e2e-link-real:80 --yes --json); url=$(printf '%s' "$json" | link_field url)
  wait_for 30 link_real_reachable "$url"
  link_daemon_stop
  wait_for 30 link_real_dead "$url"
}
link_real_dead() { [ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$1")" != 200 ]; }
link_real_reachable() { [ "$(curl -sf --max-time 5 "$1")" = link-real ]; }

# 58cee82: a paused sibling still holds the namespace (refuse); a sibling that starts later revokes the link.
t_link_paused_namespace_sibling_is_refused() {
  link_up
  ld run -d --name e2e-link-psbase --expose 80 "$IMG" sleep 600 >/dev/null
  ld run -d --name e2e-link-pssharer --network container:e2e-link-psbase "$IMG" sleep 600 >/dev/null
  ld pause e2e-link-pssharer >/dev/null
  link_refused e2e-link-psbase:80 "shares this container's network namespace"
  [ ! -f "$LINK_HOME/helper.pid" ]
  # With the sibling gone the same link is accepted, so the refusal came from the sibling alone.
  ld rm -f e2e-link-pssharer >/dev/null
  link_create e2e-link-psbase:80
  lc link stop --all
}
t_link_sibling_start_later_revokes_link() {
  link_up
  ld run -d --name e2e-link-lsbase --expose 80 "$IMG" sleep 600 >/dev/null
  ld create --name e2e-link-lssharer --network container:e2e-link-lsbase "$IMG" sleep 600 >/dev/null
  link_create e2e-link-lsbase:80
  ld start e2e-link-lssharer >/dev/null
  link_stays_revoked
}
t_link_sibling_restart_revokes_link() {
  link_up
  ld run -d --name e2e-link-rbase --expose 80 "$IMG" sleep 600 >/dev/null
  ld run -d --name e2e-link-rsharer --network container:e2e-link-rbase "$IMG" sleep 600 >/dev/null
  ld stop -t 1 e2e-link-rsharer >/dev/null
  link_create e2e-link-rbase:80
  ld restart -t 1 e2e-link-rsharer >/dev/null
  link_stays_revoked
}

