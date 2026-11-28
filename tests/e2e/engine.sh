#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: engine. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: engine
t_api_ping() {
  eq "$(curl -sf --unix-socket "$SOCK" http://localhost/_ping)" OK
  if [ "$EXTERNAL" != 1 ]; then
    local vm; vm=$(curl -sf --unix-socket "$SOCK" http://localhost/noodle/vm/status)
    python3 -c 'import json, sys; s=json.loads(sys.argv[1]); assert not s["guestAgentReady"] or s["vmRunning"]' "$vm"
  fi
}
t_api_version_negotiation() {
  nonempty "$(d version -f '{{.Server.Version}}')" server version
  nonempty "$(d version -f '{{.Server.APIVersion}}')" api version
  eq "$(d version -f '{{.Server.Os}}')" linux
}
t_info_arm64_linux() {
  eq "$(d info -f '{{.OSType}}')" linux
  case $(d info -f '{{.Architecture}}') in aarch64|arm64) ;; *) echo "bad arch"; return 1 ;; esac
  nonempty "$(d info -f '{{.NCPU}}')" ncpu
  nonempty "$(d info -f '{{.MemTotal}}')" memtotal
}
t_system_df() {
  sleeper e2e-df
  local out; out=$(d system df --format '{{.Type}} {{.TotalCount}} {{.Active}}')
  has "$out" "Images "
  has "$out" "Containers "
  has "$out" "Local Volumes "
  # the running container and the image it uses are both counted as active
  [ "$(printf '%s\n' "$out" | awk '$1=="Containers"{print $NF}')" -ge 1 ]
  [ "$(printf '%s\n' "$out" | awk '$1=="Images"{print $NF}')" -ge 1 ]
  has "$(d system df -v)" e2e-df
}
t_events_stream() {
  local out=$WORK/events.out
  d events --format '{{.Type}} {{.Action}}' >"$out" 2>&1 &
  local ev=$!
  sleep 1
  d run --rm --name e2e-ev "$IMG" true
  sleep 1
  kill "$ev" 2>/dev/null; wait "$ev" 2>/dev/null || true
  has "$(cat "$out")" "container create"
  has "$(cat "$out")" "container start"
  has "$(cat "$out")" "container die"
}

t_events_filters_since_until() {
  d network create e2e-evnet >/dev/null
  d run --name e2e-evf --label e2e.ev=1 "$IMG" sh -c 'exit 4' || true
  d rm e2e-evf >/dev/null
  sleep 1
  local now; now=$(date +%s)
  local out; out=$(d events --since 60s --until "$now" --filter container=e2e-evf --format '{{.Type}}:{{.Action}}' | tr '\n' ' ')
  has "$out" "container:create"; has "$out" "container:start"; has "$out" "container:die"; has "$out" "container:destroy"
  eq "$(d events --since 60s --until "$now" --filter container=e2e-evf --filter event=die --format '{{.Action}} {{.Actor.Attributes.exitCode}}')" "die 4"
  eq "$(d events --since 60s --until "$now" --filter container=e2e-evf --filter event=die --format '{{.Actor.Attributes.name}} {{.Actor.Attributes.image}}')" "e2e-evf $IMG"
  eq "$(d events --since 60s --until "$now" --filter container=e2e-evf --filter label=e2e.ev=1 --filter event=create --format '{{.Action}}')" create
  eq "$(d events --since 60s --until "$now" --filter container=e2e-evf --filter label=e2e.ev=2 --format '{{.Action}}')" ""
  has "$(d events --since 60s --until "$now" --filter type=network --filter network=e2e-evnet --format '{{.Type}}:{{.Action}}')" "network:create"
}
